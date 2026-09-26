#!/usr/bin/env bash
# VRChat Stream Server — универсальная установка
#
#   OBS ──RTMP──▶ MediaMTX ─┬─ RTSP  rtspt://…  → VRChat PC            (~1 с)
#                           ├─ RTMP  rtmp://…   → VRChat PC, запасной  (~1–2 с)
#                           └─ HLS ──▶ nginx (HTTP/HTTPS) → PC + Quest/Android (~3–5 с)
#
# Установка / обновление (Ubuntu 20.04+ / Debian 11+):
#   sudo bash setup.sh
#   sudo DOMAIN=stream.example.com bash setup.sh      # + HTTPS (Let's Encrypt)
#
# После установки скрипт доступен как команда `vrc-stream`:
#   sudo vrc-stream info | status | logs | restart | new-key | install | uninstall
#
# Настройки (переменные окружения; запоминаются в /etc/vrc-stream/settings.env):
#   STREAM_KEY      пароль для OBS (по умолчанию генерируется)
#   DOMAIN          домен для HTTPS (Let's Encrypt). DOMAIN= отключает HTTPS
#   EMAIL           необязательно: почта для аккаунта Let's Encrypt
#   PUBLIC_HOST     адрес сервера в ссылках, если автоопределение IP ошиблось
#   HLS_SEGMENT     длина HLS-сегмента: 1s (по умолчанию) или 2s (стабильнее на плохом интернете)
#   HLS_VARIANT     mpegts (по умолчанию, максимальная совместимость) | fmp4 | lowLatency
#   OFFLINE_SCREEN  1 (по умолчанию) — заставка, пока OBS не в эфире; нужен звук AAC 48 кГц. 0 — выключить
#   RTMP_PORT       1935
#   RTSP_PORT       8554
#   FIREWALL        1 (по умолчанию) — установить и настроить ufw (SSH не закрывается). 0 — не трогать
#   FIREWALL_EXTRA  дополнительные открытые порты через пробел, например "25565/tcp 7777/udp"
#   MEDIAMTX_VERSION  версия MediaMTX (по умолчанию v1.21.1)
set -euo pipefail

VRC_STREAM_VERSION=1.0.2
MEDIAMTX_VERSION="${MEDIAMTX_VERSION:-v1.21.1}"
SETTINGS_DIR=/etc/vrc-stream
SETTINGS_FILE=$SETTINGS_DIR/settings.env
SETTINGS_VARS=(STREAM_KEY DOMAIN EMAIL PUBLIC_HOST HLS_SEGMENT HLS_VARIANT OFFLINE_SCREEN RTMP_PORT RTSP_PORT FIREWALL FIREWALL_EXTRA HLS_CDN_SECRET)
MTX_BIN=/usr/local/bin/mediamtx
MTX_CONF=/etc/mediamtx/mediamtx.yml
MTX_HOME=/var/lib/mediamtx
MTX_API=http://127.0.0.1:9997
HLS_INTERNAL=127.0.0.1:8888
STREAM_PATH=live/stream
PUBLISH_USER=obs
SELF_BIN=/usr/local/bin/vrc-stream
NGINX_SITE=/etc/nginx/sites-available/vrc-stream.conf
NGINX_SNIPPET=/etc/nginx/snippets/vrc-stream.conf
ACME_ROOT=/var/www/letsencrypt
LE_LIVE=/etc/letsencrypt/live

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "Нужны права root: sudo $0 $*"; }

usage() {
  echo "vrc-stream $VRC_STREAM_VERSION — стрим-сервер для VRChat"
  cat <<'EOF'

  sudo vrc-stream info       ссылки для OBS и VRChat
  sudo vrc-stream status     идёт ли эфир, битрейт, число зрителей
  sudo vrc-stream logs       логи MediaMTX (Ctrl+C — выход)
  sudo vrc-stream restart    перезапустить сервисы
  sudo vrc-stream new-key    сгенерировать новый ключ для OBS
  sudo vrc-stream install    переустановить / применить настройки
  sudo vrc-stream uninstall  удалить сервер
  vrc-stream version         версия

Настройки меняются так:  sudo HLS_SEGMENT=2s vrc-stream install
EOF
}

# ---------------------------------------------------------------- настройки

load_settings() {
  # Приоритет: переменные окружения > сохранённые настройки > значения по умолчанию
  local v
  declare -A given=()
  for v in "${SETTINGS_VARS[@]}"; do
    [[ -n "${!v+x}" ]] && given[$v]="${!v}"
  done
  # shellcheck disable=SC1090
  [[ -f $SETTINGS_FILE ]] && source "$SETTINGS_FILE"
  for v in "${!given[@]}"; do
    printf -v "$v" '%s' "${given[$v]}"
  done

  : "${STREAM_KEY:=}" "${DOMAIN:=}" "${EMAIL:=}" "${PUBLIC_HOST:=}"
  : "${HLS_SEGMENT:=1s}" "${HLS_VARIANT:=mpegts}" "${OFFLINE_SCREEN:=1}"
  : "${FIREWALL:=1}" "${FIREWALL_EXTRA:=}"
  : "${RTMP_PORT:=1935}" "${RTSP_PORT:=8554}" "${HLS_CDN_SECRET:=}"
}

validate_settings() {
  [[ $HLS_SEGMENT =~ ^[0-9]+(\.[0-9]+)?(ms|s)$ ]] || die "HLS_SEGMENT: пример 1s или 2s"
  [[ $HLS_VARIANT =~ ^(mpegts|fmp4|lowLatency)$ ]] || die "HLS_VARIANT: mpegts | fmp4 | lowLatency"
  [[ $OFFLINE_SCREEN =~ ^[01]$ ]] || die "OFFLINE_SCREEN: 0 или 1"
  [[ $RTMP_PORT =~ ^[0-9]+$ && $RTSP_PORT =~ ^[0-9]+$ ]] || die "Порты должны быть числами"
  for p in "$RTMP_PORT" "$RTSP_PORT"; do
    [[ $p == 80 || $p == 443 || $p == 8888 || $p == 9997 ]] && die "Порт $p занят nginx/MediaMTX"
  done
  [[ $RTMP_PORT != "$RTSP_PORT" ]] || die "RTMP_PORT и RTSP_PORT совпадают"
  [[ $FIREWALL =~ ^[01]$ ]] || die "FIREWALL: 0 или 1"
  local rule
  for rule in $FIREWALL_EXTRA; do
    [[ $rule =~ ^[0-9]{1,5}(/(tcp|udp))?$ ]] || die "FIREWALL_EXTRA: неверное правило \"$rule\" (пример: 25565/tcp)"
  done
  if [[ -n $DOMAIN ]]; then
    [[ $DOMAIN =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "Некорректный DOMAIN: $DOMAIN"
  fi
  if [[ -n $STREAM_KEY ]]; then
    [[ $STREAM_KEY =~ ^[A-Za-z0-9_-]{8,64}$ ]] || die "STREAM_KEY: 8–64 символа, только A-Z a-z 0-9 _ -"
  fi
}

save_settings() {
  local v
  install -d -m 0700 "$SETTINGS_DIR"
  {
    echo "# vrc-stream settings — меняйте через: sudo NAME=value vrc-stream install"
    for v in "${SETTINGS_VARS[@]}"; do printf '%s=%q\n' "$v" "${!v}"; done
  } > "$SETTINGS_FILE"
  chmod 600 "$SETTINGS_FILE"
}

gen_key() { head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

ensure_key() {
  if [[ ${NEW_KEY:-0} == 1 ]]; then
    STREAM_KEY=$(gen_key)
  elif [[ -z $STREAM_KEY ]]; then
    if [[ -s /etc/nginx/stream_key ]]; then
      STREAM_KEY=$(tr -cd 'A-Za-z0-9_-' < /etc/nginx/stream_key)   # ключ от старой версии на nginx-rtmp
    fi
    [[ $STREAM_KEY =~ ^[A-Za-z0-9_-]{8,64}$ ]] || STREAM_KEY=$(gen_key)
  fi
  rm -f /etc/nginx/stream_key
  # Внутренний секрет между nginx и MediaMTX (см. hlsCDNSecret)
  [[ $HLS_CDN_SECRET =~ ^[a-f0-9]{24}$ ]] || HLS_CDN_SECRET=$(gen_key)
}

public_host() {
  if [[ -n $PUBLIC_HOST ]]; then echo "$PUBLIC_HOST"; return; fi
  if [[ -n $DOMAIN ]]; then echo "$DOMAIN"; return; fi
  local ip
  ip=$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || true)
  [[ $ip =~ ^[0-9]+(\.[0-9]+){3}$ ]] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo "${ip:-<IP_сервера>}"
}

have_cert() { [[ -n $DOMAIN && -s $LE_LIVE/$DOMAIN/fullchain.pem ]]; }

# ---------------------------------------------------------------- установка

check_os() {
  command -v apt-get >/dev/null || die "Поддерживаются только Debian/Ubuntu (нужен apt-get)"
  command -v systemctl >/dev/null || die "Нужен systemd"
}

install_packages() {
  log "Устанавливаю пакеты"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  local pkgs=(nginx curl ca-certificates tar jq)
  [[ -n $DOMAIN ]] && pkgs+=(certbot)
  apt-get update -q
  apt-get install -y -q "${pkgs[@]}"
}

backup_nginx() {
  local dir
  dir="/root/vrc-stream-backups/nginx-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$(dirname "$dir")"
  cp -a /etc/nginx "$dir"
  NGINX_BACKUP=$dir
  log "Бэкап /etc/nginx -> $dir"
}

cleanup_legacy() {
  # Остатки ручной настройки и прошлой версии скрипта на nginx-rtmp
  local conf=/etc/nginx/nginx.conf
  if [[ -f $conf ]]; then
    sed -i '\|include /etc/nginx/rtmp.conf;|d; /^[[:space:]]*rtmp_auto_push[[:space:]]/d' "$conf"
    if grep -qE '^[[:space:]]*rtmp[[:space:]]*\{' "$conf"; then
      awk '
        !skip && /^[[:space:]]*rtmp[[:space:]]*\{/ { skip = 1; depth = 0 }
        skip { depth += gsub(/[{]/, "{") - gsub(/[}]/, "}"); if (depth <= 0) skip = 0; next }
        { print }
      ' "$conf" > "$conf.new" && mv "$conf.new" "$conf"
      log "Удалён старый блок rtmp{} из nginx.conf"
    fi
  fi
  rm -f /etc/nginx/rtmp.conf \
        /etc/nginx/sites-enabled/default \
        /etc/nginx/sites-enabled/SK.conf \
        /etc/nginx/sites-enabled/stream.conf /etc/nginx/sites-available/stream.conf

  if dpkg -s libnginx-mod-rtmp >/dev/null 2>&1; then
    log "Удаляю nginx-rtmp (порт $RTMP_PORT теперь у MediaMTX)"
    apt-get purge -y -q libnginx-mod-rtmp
  fi

  if grep -qE '[[:space:]]/var/www/hls[[:space:]]' /etc/fstab; then
    sed -i '\|[[:space:]]/var/www/hls[[:space:]]|d' /etc/fstab
  fi
  if mountpoint -q /var/www/hls; then umount /var/www/hls || true; fi
}

install_mediamtx() {
  local arch current file url tmp
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7*)        arch=armv7 ;;
    armv6*)        arch=armv6 ;;
    *) die "Неподдерживаемая архитектура: $(uname -m)" ;;
  esac

  current=$([[ -x $MTX_BIN ]] && "$MTX_BIN" --version 2>/dev/null || true)
  if [[ $current == "$MEDIAMTX_VERSION" ]]; then
    log "MediaMTX $current уже установлен"
    return
  fi

  log "Скачиваю MediaMTX $MEDIAMTX_VERSION ($arch)"
  file="mediamtx_${MEDIAMTX_VERSION}_linux_${arch}.tar.gz"
  url="https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}"
  tmp=$(mktemp -d)
  curl -fsSL --retry 3 -o "$tmp/$file" "$url/$file"
  curl -fsSL --retry 3 -o "$tmp/checksums.sha256" "$url/checksums.sha256"
  (cd "$tmp" && grep -F " *$file" checksums.sha256 | sha256sum -c --quiet -) \
    || die "Контрольная сумма MediaMTX не совпала"
  tar -xzf "$tmp/$file" -C "$tmp" mediamtx
  install -m 0755 "$tmp/mediamtx" "$MTX_BIN"
  rm -rf "$tmp"
}

write_mediamtx_config() {
  id mediamtx >/dev/null 2>&1 || useradd --system --home-dir "$MTX_HOME" --no-create-home \
                                         --shell /usr/sbin/nologin mediamtx
  install -d -o mediamtx -g mediamtx -m 0750 "$MTX_HOME"
  install -d -o root -g mediamtx -m 0750 "$(dirname "$MTX_CONF")"

  local offline=""
  if [[ $OFFLINE_SCREEN == 1 ]]; then
    offline="
  # Заставка, пока OBS не в эфире: плееры не отключаются при перезапуске OBS.
  # OBS должен отдавать H.264 + AAC 48 кГц стерео.
  $STREAM_PATH:
    alwaysAvailable: true
    alwaysAvailableTracks:
      - codec: H264
      - codec: MPEG4Audio
        sampleRate: 48000
        channelCount: 2"
  fi

  cat > "$MTX_CONF" <<EOF
# Сгенерировано vrc-stream. Не редактируйте вручную — используйте: sudo NAME=value vrc-stream install
logLevel: info
logDestinations: [stdout]

readTimeout: 10s
writeTimeout: 10s
# Больше очередь — меньше выпадений кадров у медленных зрителей
writeQueueSize: 1024

# ---- Доступ: публиковать может только OBS с ключом, смотреть — все
authMethod: internal
authInternalUsers:
  - user: $PUBLISH_USER
    pass: "$STREAM_KEY"
    ips: []
    permissions:
      - action: publish
        path:
  - user: any
    pass:
    ips: []
    permissions:
      - action: read
        path:
  - user: any
    pass:
    ips: ["127.0.0.1", "::1"]
    permissions:
      - action: api

api: true
apiAddress: 127.0.0.1:9997
metrics: false
pprof: false
playback: false

# ---- RTSP: rtspt:// для VRChat PC. Только TCP — работает через любой NAT/фаервол
rtsp: true
rtspTransports: [tcp]
rtspEncryption: "no"
rtspAddress: :$RTSP_PORT

# ---- RTMP: приём от OBS + просмотр на PC
rtmp: true
rtmpEncryption: "no"
rtmpAddress: :$RTMP_PORT

# ---- HLS: наружу раздаёт nginx (HTTP/HTTPS)
hls: true
hlsAddress: $HLS_INTERNAL
hlsEncryption: false
hlsAllowOrigins: ["*"]
hlsTrustedProxies: ["127.0.0.1"]
# nginx передаёт этот секрет, и MediaMTX отдаёт "простой" HLS: без редиректов,
# cookie и сессионных параметров в ссылках — так его понимает любой плеер (AVPro, ExoPlayer)
hlsCDNSecret: "$HLS_CDN_SECRET"
# Сегменты готовы заранее — первый зритель не ждёт и не получает ошибку
hlsAlwaysRemux: true
hlsVariant: $HLS_VARIANT
hlsSegmentCount: 7
# Должно совпадать с интервалом ключевых кадров в OBS
hlsSegmentDuration: $HLS_SEGMENT
hlsPartDuration: 200ms
hlsSegmentMaxSize: 50M
hlsMuxerCloseAfter: 60s

webrtc: false
srt: false
moq: false

pathDefaults:
  # Переподключившийся OBS сразу заменяет "зависшее" старое подключение
  overridePublisher: true

paths:$offline
  all_others:
EOF
  chown root:mediamtx "$MTX_CONF"
  chmod 0640 "$MTX_CONF"
}

write_mediamtx_service() {
  cat > /etc/systemd/system/mediamtx.service <<EOF
[Unit]
Description=MediaMTX (vrc-stream)
After=network-online.target
Wants=network-online.target

[Service]
User=mediamtx
Group=mediamtx
WorkingDirectory=$MTX_HOME
ExecStart=$MTX_BIN $MTX_CONF
Restart=always
RestartSec=2
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$MTX_HOME

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable mediamtx >/dev/null
}

write_nginx() {
  install -d "$ACME_ROOT" /etc/nginx/snippets

  cat > "$NGINX_SNIPPET" <<EOF
# Сгенерировано vrc-stream
location = /health {
    default_type text/plain;
    return 200 "ok\n";
}

location ^~ /.well-known/acme-challenge/ {
    root $ACME_ROOT;
}

# HLS: /live/stream/index.m3u8 -> MediaMTX
location / {
    proxy_pass http://$HLS_INTERNAL;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    # CDN-режим MediaMTX: обычный HLS без редиректов и cookie
    proxy_set_header Authorization "Bearer $HLS_CDN_SECRET";
    proxy_buffering off;
    proxy_read_timeout 60s;
    access_log /var/log/nginx/vrc-stream.access.log vrc_stream;
}
EOF
  chmod 0640 "$NGINX_SNIPPET"

  local v6_80="" v6_443="" name="${DOMAIN:-_}"
  if [[ -f /proc/net/if_inet6 ]]; then
    v6_80="listen [::]:80 default_server;"
    v6_443="listen [::]:443 ssl default_server;"
  fi

  {
    cat <<EOF
# Сгенерировано vrc-stream
# Формат лога для подсчёта HLS-зрителей в "vrc-stream status"
log_format vrc_stream '\$msec \$remote_addr \$status \$request_uri';

server {
    listen 80 default_server;
    $v6_80
    server_name $name;
    server_tokens off;
    include $NGINX_SNIPPET;
}
EOF
    if have_cert; then
      cat <<EOF

server {
    listen 443 ssl default_server;
    $v6_443
    server_name $DOMAIN;
    server_tokens off;
    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include $NGINX_SNIPPET;
}
EOF
    fi
  } > "$NGINX_SITE"
  ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/vrc-stream.conf

  nginx -t 2>/dev/null || { nginx -t; die "Ошибка в конфиге nginx. Бэкап: ${NGINX_BACKUP:-нет}"; }
}

obtain_cert() {
  [[ -n $DOMAIN ]] || return 0
  local resolved myip
  resolved=$(getent ahostsv4 "$DOMAIN" | awk '{print $1; exit}' || true)
  myip=$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || true)
  if [[ -z $resolved ]]; then
    warn "Домен $DOMAIN не резолвится — HTTPS пропущен. Проверьте A-запись и перезапустите: sudo vrc-stream install"
    return 0
  fi
  if [[ -n $myip && $resolved != "$myip" ]]; then
    warn "$DOMAIN указывает на $resolved, а IP сервера $myip — Let's Encrypt может не выдать сертификат"
  fi

  # Почта нужна только для аккаунта Let's Encrypt; продление всё равно автоматическое
  local email_opt=(--register-unsafely-without-email)
  [[ -n $EMAIL ]] && email_opt=(-m "$EMAIL")

  log "Получаю сертификат Let's Encrypt для $DOMAIN"
  if certbot certonly --webroot -w "$ACME_ROOT" --cert-name "$DOMAIN" -d "$DOMAIN" \
       "${email_opt[@]}" --agree-tos -n --keep-until-expiring \
       --deploy-hook "systemctl reload nginx"; then
    write_nginx
    systemctl reload nginx
  else
    warn "Сертификат не получен — сервер работает по HTTP. Проверьте DNS и порт 80, затем: sudo vrc-stream install"
  fi
}

# Порты SSH, которые нельзя закрывать: из конфига sshd, по активным подключениям и всегда 22
ssh_ports() {
  {
    echo 22
    sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }'
    grep -hiE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null \
      | awk '{ print $2 }'
    ss -Htlnp 2>/dev/null | awk '/"sshd"/ { n = split($4, a, ":"); print a[n] }'
    [[ -n ${SSH_CONNECTION:-} ]] && awk '{ print $4 }' <<<"$SSH_CONNECTION"
  } | grep -E '^[0-9]+$' | sort -un
}

# Порты, которые кто-то слушает снаружи, но которые не будут открыты в ufw
closed_listening_ports() {
  local allowed=" $* "
  ss -Htuln 2>/dev/null | awk '{ print $1, $5 }' | while read -r proto addr; do
    case $addr in 127.*|\[::1\]*|::1*) continue ;; esac
    local port=${addr##*:}
    [[ $proto == udp && $port =~ ^(68|546|5353)$ ]] && continue   # DHCP/mDNS клиента
    [[ $allowed == *" $port/$proto "* || $allowed == *" $port "* ]] && continue
    echo "$port/$proto"
  done | sort -u | tr '\n' ' '
}

setup_firewall() {
  if [[ $FIREWALL != 1 ]]; then
    log "Фаервол: пропускаю (FIREWALL=0)"
    return 0
  fi

  if ! command -v ufw >/dev/null; then
    log "Устанавливаю ufw"
    apt-get install -y -q ufw
  fi

  local was_active=0 p ssh rules=() closed
  ufw status 2>/dev/null | grep -q "Status: active" && was_active=1

  ssh=$(ssh_ports | tr '\n' ' '); ssh=${ssh% }
  for p in $ssh; do rules+=("$p/tcp:SSH"); done
  # 80 открыт всегда: по нему Let's Encrypt проверяет домен при каждом продлении сертификата
  rules+=("80/tcp:vrc-stream HTTP, Let's Encrypt" "443/tcp:vrc-stream HTTPS"
          "$RTMP_PORT/tcp:vrc-stream RTMP (OBS)" "$RTSP_PORT/tcp:vrc-stream RTSP")
  for p in $FIREWALL_EXTRA; do rules+=("$p:vrc-stream extra"); done

  for p in "${rules[@]}"; do
    ufw allow "${p%%:*}" comment "${p#*:}" >/dev/null
  done

  if (( was_active )); then
    log "ufw уже включён — добавлены правила: SSH ($ssh), 80, 443, $RTMP_PORT, $RTSP_PORT${FIREWALL_EXTRA:+, $FIREWALL_EXTRA}"
    return 0
  fi

  # Включаем впервые: по умолчанию закрыто всё входящее, кроме разрешённого выше
  closed=$(closed_listening_ports $ssh 80 443 "$RTMP_PORT" "$RTSP_PORT" $FIREWALL_EXTRA)
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw --force enable >/dev/null
  log "ufw включён: открыты SSH ($ssh), 80, 443, $RTMP_PORT, $RTSP_PORT${FIREWALL_EXTRA:+, $FIREWALL_EXTRA}"
  if [[ -n ${closed// /} ]]; then
    warn "Эти порты слушаются на сервере, но теперь закрыты фаерволом: $closed"
    warn "Если они нужны снаружи: sudo FIREWALL_EXTRA=\"${closed% }\" vrc-stream install"
  fi
}

# 80 и 443 не закрываем никогда: 80 нужен Let's Encrypt для продления сертификата,
# 443 — HTTPS; SSH тоже остаётся открытым
remove_firewall_rules() {
  command -v ufw >/dev/null || return 0
  local p
  for p in "$RTMP_PORT/tcp" "$RTSP_PORT/tcp" $FIREWALL_EXTRA; do
    ufw delete allow "$p" >/dev/null 2>&1 || true
  done
}

wait_ready() {
  local i
  for i in $(seq 1 30); do
    curl -fsS --max-time 2 "$MTX_API/v3/paths/list" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  journalctl -u mediamtx -n 30 --no-pager || true
  die "MediaMTX не запустился (лог выше)"
}

install_self() {
  local src
  src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)
  if [[ -f $src && $src != "$SELF_BIN" ]]; then
    install -m 0755 "$src" "$SELF_BIN"
  fi
}

cmd_install() {
  check_os
  load_settings
  validate_settings
  install_packages
  backup_nginx
  cleanup_legacy
  ensure_key
  validate_settings
  save_settings

  install_mediamtx
  write_mediamtx_config
  write_mediamtx_service

  log "Настраиваю nginx"
  write_nginx
  systemctl enable nginx >/dev/null
  systemctl restart nginx          # restart, а не reload: освобождает порт старого nginx-rtmp

  log "Запускаю MediaMTX"
  systemctl restart mediamtx
  wait_ready

  setup_firewall
  obtain_cert
  install_self
  write_heal_timer

  curl -fsS --max-time 3 http://127.0.0.1/health >/dev/null || warn "nginx не отвечает на /health"
  cmd_info
}

cmd_new_key() {
  load_settings
  NEW_KEY=1 ensure_key
  save_settings
  write_mediamtx_config
  systemctl restart mediamtx
  wait_ready
  log "Новый ключ создан. Обновите его в OBS."
  cmd_info
}

# ---------------------------------------------------------------- информация

cmd_info() {
  [[ -f $SETTINGS_FILE ]] || die "Сервер не установлен: sudo bash setup.sh"
  load_settings
  local host rtmp_host hls_base
  host=$(public_host)
  rtmp_host=$host; [[ $RTMP_PORT != 1935 ]] && rtmp_host="$host:$RTMP_PORT"
  if have_cert; then hls_base="https://$DOMAIN"; else hls_base="http://$host"; fi

  cat <<EOF

═══════════════════════════ OBS ═══════════════════════════
  Настройки → Трансляция → Сервис: Настраиваемый
  Сервер:       rtmp://$rtmp_host/live
  Ключ потока:  stream?user=$PUBLISH_USER&pass=$STREAM_KEY

  Настройки → Вывод (Расширенный):
  H.264, CBR, интервал ключевых кадров = ${HLS_SEGMENT}, аудио AAC 48 кГц

═══════════════════════ ССЫЛКИ ДЛЯ VRChat ═══════════════════════
  Для всех (PC + Quest):     $hls_base/$STREAM_PATH/index.m3u8
  PC, минимальная задержка:  rtspt://$host:$RTSP_PORT/$STREAM_PATH
  PC, запасной вариант:      rtmp://$rtmp_host/$STREAM_PATH

  Проверка в браузере:       $hls_base/$STREAM_PATH/
  Зрителям нужно включить в VRChat «Allow Untrusted URLs».
════════════════════════════════════════════════════════════════
EOF
  if [[ -n $DOMAIN ]] && ! have_cert; then
    warn "HTTPS для $DOMAIN ещё не настроен — Quest может не воспроизводить http-ссылку"
  elif [[ -z $DOMAIN ]]; then
    echo "  Совет: для Quest лучше HTTPS — sudo DOMAIN=... vrc-stream install"
  fi
}

cmd_status() {
  local svc
  for svc in mediamtx nginx; do
    if systemctl is-active --quiet "$svc"; then
      printf '%-9s работает\n' "$svc:"
    else
      printf '%-9s \033[1;31mНЕ РАБОТАЕТ\033[0m  (sudo journalctl -u %s -n 50)\n' "$svc:" "$svc"
    fi
  done
  cert_status

  local a b
  a=$(curl -fsS --max-time 3 "$MTX_API/v3/paths/list") || die "API MediaMTX недоступно"
  if [[ $(jq '.itemCount' <<<"$a") == 0 ]]; then
    echo "Эфира нет: OBS не подключён."
    return 0
  fi
  sleep 2
  b=$(curl -fsS --max-time 3 "$MTX_API/v3/paths/list") || die "API MediaMTX недоступно"

  jq -rn --argjson a "$a" --argjson b "$b" '
    def kind: if test("^rtsp") then "RTSP" elif test("^rtmp") then "RTMP" else . end;
    def track: .codec
      + (if .codecProps.width then " \(.codecProps.width)x\(.codecProps.height)" else "" end)
      + (if .codecProps.sampleRate then " \(.codecProps.sampleRate) Гц" else "" end);
    $b.items[] as $p
    | ([$a.items[] | select(.name == $p.name) | .inboundBytes][0] // $p.inboundBytes) as $prev
    | [$p.readers[]? | select(.type != "hidden" and .type != "hlsSession") | .type | kind] as $r
    | (if $p | has("online") then $p.online else $p.ready end) as $live
    | "",
      "Поток: \($p.name)   \(if $live then "● В ЭФИРЕ" else "○ OBS не подключён (идёт заставка)" end)",
      "  Дорожки:   \([$p.tracks2[]? | track] | join(", "))",
      (if $live then "  Битрейт:   \((($p.inboundBytes - $prev) * 8 / 2 / 1000) | floor) Кбит/с (входящий от OBS)" else empty end),
      "  RTSP/RTMP: \($r | length)" +
        (if ($r | length) > 0 then "  (" + ($r | group_by(.) | map("\(.[0]): \(length)") | join(", ")) + ")" else "" end)
  '
  echo
  echo "Зрители HLS (уникальные IP за 20 с, все потоки): $(hls_viewers)"

  local live
  live=$(jq -r --arg n "$STREAM_PATH" \
    '[.items[] | select(.name == $n) | (if has("online") then .online else .ready end)][0] // false' <<<"$b")
  hls_latency_check "$live"
}

# Срок действия сертификата. certbot продлевает его сам за 30 дней до конца
# (проверка домена идёт через порт 80) — если осталось меньше 20 дней, продление не срабатывает.
cert_status() {
  if [[ -r $SETTINGS_FILE ]]; then load_settings; fi
  [[ -n ${DOMAIN:-} ]] || return 0
  local crt=$LE_LIVE/$DOMAIN/fullchain.pem end days
  if [[ ! -r $crt ]]; then
    echo "HTTPS:    сертификат для $DOMAIN не найден (или нужен sudo)"
    return 0
  fi
  end=$(openssl x509 -enddate -noout -in "$crt" | cut -d= -f2)
  days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
  echo "HTTPS:    сертификат $DOMAIN действует ещё $days дн. (продлевается автоматически)"
  if (( days < 20 )); then
    warn "Сертификат не продлился вовремя. Проверьте: sudo certbot renew --dry-run (порт 80 должен быть открыт)"
  fi
}

# TARGETDURATION и самый длинный сегмент в текущем HLS-плейлисте: "5 1.0".
# В MediaMTX TARGETDURATION только растёт (до перезапуска), а плееры держат
# отставание ~3 × TARGETDURATION — один длинный сегмент надолго увеличивает задержку.
hls_playlist_info() {
  local base=${HLS_CHECK_BASE:-http://127.0.0.1} idx media pl td maxinf
  idx=$(curl -fsS --max-time 3 "$base/$STREAM_PATH/index.m3u8" 2>/dev/null) || return 1
  media=$(grep -v '^#' <<<"$idx" | grep -m1 . || true)
  [[ -n $media ]] || return 1
  pl=$(curl -fsS --max-time 3 "$base/$STREAM_PATH/$media" 2>/dev/null) || return 1
  td=$(sed -n 's/^#EXT-X-TARGETDURATION:\([0-9]*\).*/\1/p' <<<"$pl")
  [[ -n $td ]] || return 1
  maxinf=$(awk -F'[:,]' '/^#EXTINF/ { if ($2 + 0 > m) m = $2 + 0 } END { printf "%.1f", m }' <<<"$pl")
  echo "$td $maxinf"
}

# HLS_SEGMENT в целых секундах, с округлением вверх: 1s -> 1, 1500ms -> 2
segment_seconds() {
  local s=${HLS_SEGMENT:-1s}
  if [[ $s == *ms ]]; then
    echo $(( (${s%ms} + 999) / 1000 ))
  else
    awk -v s="${s%s}" 'BEGIN { printf "%d", (s == int(s)) ? s : int(s) + 1 }'
  fi
}

hls_latency_check() {
  local live=$1 td maxinf want
  read -r td maxinf < <(hls_playlist_info) || return 0
  if [[ -r $SETTINGS_FILE ]]; then load_settings; fi
  want=$(segment_seconds)

  echo "HLS: сегменты сейчас до ${maxinf} с, TARGETDURATION ${td} с → задержка у зрителей ≈ $(( td * 3 )) с"
  if [[ $live == true ]] && awk -v m="$maxinf" -v w="$want" 'BEGIN { exit !(m > w + 0.5) }'; then
    warn "Сегменты длиннее ${want} с: в OBS интервал ключевых кадров должен быть ${want} s (не 0/авто)"
  elif (( td > want )); then
    warn "TARGETDURATION вырос до ${td} с (был длинный сегмент при обрыве/переподключении OBS)."
    warn "Сбросится сам, когда OBS не в эфире и никто не смотрит (проверка раз в минуту)."
    warn "Сбросить сразу: sudo vrc-stream restart — зрителям придётся перезапустить видео."
  fi
}

# Уникальные IP, скачивавшие HLS-сегменты за последние $1 секунд (по умолчанию 20)
hls_viewers() {
  local log=/var/log/nginx/vrc-stream.access.log window=${1:-20}
  [[ -r $log ]] || { echo "? (нужен sudo)"; return 0; }
  tail -n 50000 "$log" \
    | awk -v t="$(( $(date +%s) - window ))" '$1 >= t && $3 ~ /^2/ && $4 ~ /\.(ts|mp4|m4s)(\?|$)/ { print $2 }' \
    | sort -u | wc -l
}

# Запускается таймером vrc-stream-heal.timer раз в минуту: если TARGETDURATION вырос,
# а OBS не в эфире и никто не смотрит — перезапускает MediaMTX, возвращая низкую задержку.
cmd_heal() {
  local json live readers td maxinf want stamp=${HEAL_STAMP:-/run/vrc-stream-heal.stamp}
  load_settings
  json=$(curl -fsS --max-time 3 "$MTX_API/v3/paths/list" 2>/dev/null) || return 0

  live=$(jq -r --arg n "$STREAM_PATH" \
    '[.items[] | select(.name == $n) | (if has("online") then .online else .ready end)][0] // false' <<<"$json")
  [[ $live == false ]] || return 0
  readers=$(jq '[.items[].readers[]? | select(.type != "hidden" and .type != "hlsSession")] | length' <<<"$json")
  [[ $readers == 0 ]] || return 0
  [[ $(hls_viewers 120) == 0 ]] || return 0

  read -r td maxinf < <(hls_playlist_info) || return 0
  want=$(segment_seconds)
  (( td > want )) || return 0

  # Не чаще раза в 10 минут — на случай, если что-то пойдёт не так
  if [[ -f $stamp ]] && (( $(date +%s) - $(stat -c %Y "$stamp") < 600 )); then return 0; fi
  touch "$stamp"
  echo "TARGETDURATION ${td} с > ${want} с, эфира и зрителей нет — перезапускаю MediaMTX для сброса задержки HLS"
  systemctl restart mediamtx
}

write_heal_timer() {
  if [[ ! -x $SELF_BIN ]]; then
    warn "Команда $SELF_BIN не установлена — автосброс задержки HLS не включён"
    return 0
  fi
  cat > /etc/systemd/system/vrc-stream-heal.service <<EOF
[Unit]
Description=vrc-stream: сброс задержки HLS, когда нет эфира и зрителей
After=mediamtx.service nginx.service

[Service]
Type=oneshot
ExecStart=$SELF_BIN heal
EOF
  cat > /etc/systemd/system/vrc-stream-heal.timer <<'EOF'
[Unit]
Description=vrc-stream: проверка задержки HLS раз в минуту

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=15s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now vrc-stream-heal.timer >/dev/null 2>&1
}

# ---------------------------------------------------------------- удаление

cmd_uninstall() {
  log "Удаляю vrc-stream"
  if [[ -r $SETTINGS_FILE ]]; then load_settings; remove_firewall_rules; fi
  systemctl disable --now vrc-stream-heal.timer mediamtx 2>/dev/null || true
  rm -f /etc/systemd/system/vrc-stream-heal.service /etc/systemd/system/vrc-stream-heal.timer
  rm -f /etc/systemd/system/mediamtx.service
  systemctl daemon-reload
  rm -f "$MTX_BIN" /etc/nginx/sites-enabled/vrc-stream.conf "$NGINX_SITE" "$NGINX_SNIPPET"
  rm -rf "$(dirname "$MTX_CONF")" "$MTX_HOME" "$SETTINGS_DIR"
  id mediamtx >/dev/null 2>&1 && userdel mediamtx 2>/dev/null || true
  if command -v nginx >/dev/null && nginx -t 2>/dev/null; then systemctl reload nginx || true; fi
  rm -f "$SELF_BIN"
  log "Готово. nginx и сертификаты Let's Encrypt оставлены."
}

# ---------------------------------------------------------------- main

main() {
  local cmd=${1:-}
  if [[ -z $cmd ]]; then
    if [[ $(basename "$0") == vrc-stream ]]; then cmd=help; else cmd=install; fi
  fi
  case $cmd in
    install|update) need_root; cmd_install ;;
    info)           need_root; cmd_info ;;
    status)         cmd_status ;;
    logs)           exec journalctl -u mediamtx -n 100 -f ;;
    restart)        need_root; systemctl restart nginx mediamtx; wait_ready; cmd_status ;;
    new-key)        need_root; cmd_new_key ;;
    uninstall)      need_root; cmd_uninstall ;;
    heal)           need_root; cmd_heal ;;
    version|--version) echo "vrc-stream $VRC_STREAM_VERSION (MediaMTX $MEDIAMTX_VERSION)" ;;
    help|-h|--help) usage ;;
    *)              usage; exit 1 ;;
  esac
}

main "$@"

#!/usr/bin/env bash
# Полная установка целиком: `setup.sh install` в отдельном процессе bash — как на сервере
# (set -e, ловушка ошибок, без SSH_CONNECTION, как под sudo), но с корнем во временной папке
# и подставными системными командами. Ловит ошибки на стыках шагов, которые не видны
# в тестах отдельных функций (все три бага 1.1.x были такими).
source "$(dirname "$0")/../lib.sh"

BASE_MOCKS=(apt-get pgrep ss sshd systemctl dpkg mountpoint umount useradd userdel id install chown nginx certbot getent curl)

# Запуск setup.sh с системными путями внутри $FAKE_ROOT
cat > "$T_TMP/runner.sh" <<EOF
#!/usr/bin/env bash
VRC_STREAM_TEST=1 source "$T_ROOT/setup.sh"
R=\$FAKE_ROOT
SETTINGS_DIR=\$R/etc/vrc-stream;        SETTINGS_FILE=\$SETTINGS_DIR/settings.env
MTX_BIN=\$R/usr/local/bin/mediamtx;     MTX_CONF=\$R/etc/mediamtx/mediamtx.yml; MTX_HOME=\$R/var/lib/mediamtx
SELF_BIN=\$R/usr/local/bin/vrc-stream
NGINX_DIR=\$R/etc/nginx
NGINX_SITE=\$NGINX_DIR/sites-available/vrc-stream.conf; NGINX_SNIPPET=\$NGINX_DIR/snippets/vrc-stream.conf
NGINX_ACCESS_LOG=\$R/var/log/nginx/vrc-stream.access.log; BACKUP_DIR=\$R/root/vrc-stream-backups
FSTAB=\$R/etc/fstab;                    LEGACY_HLS_DIR=\$R/var/www/hls
ACME_ROOT=\$R/var/www/letsencrypt;      LE_LIVE=\$R/etc/letsencrypt/live
F2B_JAIL=\$R/etc/fail2ban/jail.d/vrc-stream.conf; F2B_SSHD=\$R/etc/fail2ban/jail.d/vrc-stream-sshd.conf
F2B_FILTER=\$R/etc/fail2ban/filter.d/vrc-stream-mediamtx.conf
SYSTEMD_DIR=\$R/etc/systemd/system;     DPKG_LOG=\$R/var/log/dpkg.log
export HEAL_STAMP=\$R/run/heal.stamp
# Страховка: ни один путь, куда пишет установка, не должен вести за пределы временного корня
for v in SETTINGS_DIR MTX_BIN MTX_CONF MTX_HOME SELF_BIN NGINX_DIR NGINX_SITE NGINX_SNIPPET NGINX_ACCESS_LOG \\
         BACKUP_DIR FSTAB LEGACY_HLS_DIR ACME_ROOT LE_LIVE F2B_JAIL F2B_SSHD F2B_FILTER SYSTEMD_DIR DPKG_LOG; do
  [[ \${!v} == "\$R"/* ]] || { echo "ТЕСТ ОСТАНОВЛЕН: \$v=\${!v} вне \$R" >&2; exit 99; }
done
need_root() { :; }
sleep() { :; }                          # ожидание apt и сервисов — без реальных пауз
has_cmd() {                             # ufw/fail2ban/nft — только подставные, не системные
  case \$1 in ufw|fail2ban-client|nft) [[ -x \$MOCK_BIN/\$1 ]] ;; *) command -v "\$1" >/dev/null 2>&1 ;; esac
}
main "\$@"
EOF

new_root() { # new_root имя — «свежий сервер»: nginx из пакета, сайт default, пустой fstab
  local r=$T_TMP/root-$1
  mkdir -p "$r"/etc/nginx/{sites-available,sites-enabled,snippets} "$r"/etc/systemd/system \
           "$r"/usr/local/bin "$r"/var/log/nginx "$r"/var/lib "$r"/run
  printf 'events {}\nhttp {\n    include /etc/nginx/sites-enabled/*;\n}\n' > "$r/etc/nginx/nginx.conf"
  echo 'server { listen 80 default_server; }' > "$r/etc/nginx/sites-enabled/default"
  : > "$r/etc/fstab"
  printf '%s\n' '#!/bin/sh' 'echo v1.21.1' > "$r/usr/local/bin/mediamtx"   # MediaMTX уже скачан
  chmod +x "$r/usr/local/bin/mediamtx"
  echo "$r"
}
fresh_state() { rm -rf "${MOCK_STATE:?}"/*; unmock ufw fail2ban-client; mock "${BASE_MOCKS[@]}"; reset_calls; }

setup_run() { # setup_run корень команда [ПЕРЕМЕННАЯ=значение…] — вывод в $out, код в $rc
  local r=$1 cmd=$2; shift 2
  env -u SSH_CONNECTION FAKE_ROOT="$r" MOCK_LE_LIVE="$r/etc/letsencrypt/live" "$@" \
    bash "$T_TMP/runner.sh" "$cmd" > "$T_TMP/out.txt" 2>&1
  rc=$?
  out=$(strip_colors < "$T_TMP/out.txt")
}
line_of() { calls | grep -n -- "$1" | head -n 1 | cut -d: -f1; }
before()  { local a b; a=$(line_of "$1"); b=$(line_of "$2"); [[ -n $a && -n $b && $a -lt $b ]]; }
key_of()  { sed -n 's/^STREAM_KEY=//p' "$1/etc/vrc-stream/settings.env"; }

# ---------------------------------------------------------------------------
section "Свежая VM: HTTPS, ufw и fail2ban не установлены, идут обновления, sudo без SSH_CONNECTION"
R=$(new_root fresh); fresh_state
echo 3 > "$MOCK_STATE/apt_busy"; touch "$MOCK_STATE/sshd_fail"
setup_run "$R" install DOMAIN=stream.example.test
expect_eq    "установка завершилась успешно (код 0)"   "$rc" "0"
expect_hasnt "без неожиданных ошибок"                   "$out" "[x]"
expect_has   "дождалась обновлений системы"             "$out" "apt занят: unattended-upgrade"
expect_has   "ufw включён"                              "$out" "ufw включён: открыты SSH (22)"
expect_has   "fail2ban настроен"                        "$out" "fail2ban: бан после 20"
expect_has   "сертификат запрошен"                      "$out" "Получаю сертификат Let's Encrypt для stream.example.test"
expect_has   "итог: HTTPS-ссылка для всех"              "$out" "https://stream.example.test/live/stream/index.m3u8"
expect_has   "итог: ссылка для OBS"                     "$out" "rtmp://stream.example.test/live"
check "порядок: apt update → install пакетов"           before "apt-get -o DPkg::Lock::Timeout=900 update" "install -y -q nginx"
check "порядок: SSH разрешён до включения ufw"          before "ufw allow 22/tcp" "ufw --force enable"
check "порядок: ufw включён до запроса сертификата"     before "ufw --force enable" "certbot certonly"
check "порядок: MediaMTX перезапущен до фаервола"       before "systemctl restart mediamtx" "ufw --force enable"
check "порядок: после сертификата nginx перечитан"      before "certbot certonly" "^systemctl reload nginx"
expect_has   "certbot: webroot и без почты"             "$(calls)" "--webroot -w $R/var/www/letsencrypt"
expect_has   "…без почты"                               "$(calls)" "--register-unsafely-without-email"
expect_has   "пользователь mediamtx создан"             "$(calls)" "useradd --system"
expect_has   "таймер автосброса включён"                "$(calls)" "systemctl enable --now vrc-stream-heal.timer"
check "настройки сохранены"                             test -s "$R/etc/vrc-stream/settings.env"
check "ключ OBS — 24 hex"                               bash -c '[[ $(sed -n "s/^STREAM_KEY=//p" "$1") =~ ^[0-9a-f]{24}$ ]]' _ "$R/etc/vrc-stream/settings.env"
check "конфиг MediaMTX записан"                         grep -q 'hlsCDNSecret:' "$R/etc/mediamtx/mediamtx.yml"
check "сервис MediaMTX записан"                         test -s "$R/etc/systemd/system/mediamtx.service"
check "сайт nginx с HTTPS (443)"                        grep -q 'listen 443 ssl' "$R/etc/nginx/sites-available/vrc-stream.conf"
check "…и с путём к сертификату"                        grep -q "$R/etc/letsencrypt/live/stream.example.test/fullchain.pem" "$R/etc/nginx/sites-available/vrc-stream.conf"
check "сайт default отключён"                           test ! -e "$R/etc/nginx/sites-enabled/default"
check "правила fail2ban записаны"                       test -s "$R/etc/fail2ban/jail.d/vrc-stream.conf"
check "команда vrc-stream установлена"                  test -s "$R/usr/local/bin/vrc-stream"
check "бэкап nginx сделан"                              bash -c 'ls -d "$1"/root/vrc-stream-backups/nginx-* >/dev/null 2>&1' _ "$R"
KEY1=$(key_of "$R")

section "Повторный запуск на том же сервере"
reset_calls
setup_run "$R" install
expect_eq    "успешно (код 0)"                          "$rc" "0"
expect_hasnt "без неожиданных ошибок"                   "$out" "[x]"
expect_eq    "ключ OBS не изменился"                    "$(key_of "$R")" "$KEY1"
expect_has   "домен запомнился (HTTPS-ссылка)"          "$out" "https://stream.example.test/live/stream/index.m3u8"
expect_has   "ufw не включается заново"                 "$out" "ufw уже включён"
expect_hasnt "ufw и fail2ban не переустанавливаются"    "$(calls)" "install -y -q ufw"
expect_hasnt "…fail2ban тоже"                           "$(calls)" "install -y -q fail2ban"

section "Старая установка на nginx-rtmp (ручная настройка из начала проекта)"
R=$(new_root legacy); fresh_state
cat > "$R/etc/nginx/nginx.conf" <<'EOF'
events {}
http {
    include /etc/nginx/sites-enabled/*;
}
rtmp {
server {
listen 1935; # the port
application live { # "live" comment
  live on;
  hls on;
}
}
}
include /etc/nginx/rtmp.conf;
EOF
echo 'server { listen 80; location /hls/ { alias /var/www/hls/; } }' > "$R/etc/nginx/sites-enabled/SK.conf"
echo "oldkey123456abcdef" > "$R/etc/nginx/stream_key"
echo "tmpfs $R/var/www/hls tmpfs defaults,size=512M 0 0" > "$R/etc/fstab"
touch "$MOCK_STATE/rtmp_installed" "$MOCK_STATE/hls_mounted"
setup_run "$R" install
expect_eq    "успешно (код 0)"                          "$rc" "0"
expect_hasnt "без неожиданных ошибок"                   "$out" "[x]"
check "блок rtmp{} удалён из nginx.conf"                not grep -q 'rtmp' "$R/etc/nginx/nginx.conf"
check "…http{} на месте"                                grep -q 'include /etc/nginx/sites-enabled' "$R/etc/nginx/nginx.conf"
check "SK.conf удалён"                                  test ! -e "$R/etc/nginx/sites-enabled/SK.conf"
expect_has   "модуль nginx-rtmp удалён"                 "$(calls)" "purge -y -q libnginx-mod-rtmp"
check "tmpfs убран из fstab"                            not grep -q 'hls' "$R/etc/fstab"
expect_has   "tmpfs отмонтирован"                       "$(calls)" "umount $R/var/www/hls"
expect_eq    "старый ключ OBS перенесён"                "$(key_of "$R")" "oldkey123456abcdef"
check "старый файл ключа удалён"                        test ! -e "$R/etc/nginx/stream_key"

section "Без домена, FIREWALL=0, FAIL2BAN=0"
R=$(new_root minimal); fresh_state
setup_run "$R" install FIREWALL=0 FAIL2BAN=0
expect_eq    "успешно (код 0)"                          "$rc" "0"
expect_hasnt "ufw не трогается"                         "$(calls)" "ufw "
expect_hasnt "fail2ban не ставится"                     "$(calls)" "fail2ban"
expect_hasnt "certbot не вызывается"                    "$(calls)" "certbot"
expect_has   "HTTP-ссылка по внешнему IP"               "$out" "http://203.0.113.50/live/stream/index.m3u8"
check "без HTTPS (443)"                                 not grep -q 'listen 443' "$R/etc/nginx/sites-available/vrc-stream.conf"

section "Домен не резолвится / Let's Encrypt отказал — установка всё равно завершается"
R=$(new_root nodns); fresh_state; touch "$MOCK_STATE/dns_fail"
setup_run "$R" install DOMAIN=stream.example.test
expect_eq    "DNS: успешно (код 0)"                     "$rc" "0"
expect_has   "DNS: понятное предупреждение"             "$out" "не резолвится — HTTPS пропущен"
expect_hasnt "DNS: certbot не вызывается"               "$(calls)" "certbot certonly"
R=$(new_root lefail); fresh_state; touch "$MOCK_STATE/certbot_fail"
setup_run "$R" install DOMAIN=stream.example.test
expect_eq    "certbot: успешно (код 0)"                 "$rc" "0"
expect_has   "certbot: предупреждение"                  "$out" "Сертификат не получен — сервер работает по HTTP"
check "certbot: без HTTPS (443)"                        not grep -q 'listen 443' "$R/etc/nginx/sites-available/vrc-stream.conf"

section "Ошибка в конфиге nginx — остановка с понятным сообщением"
R=$(new_root nginxbad); fresh_state; touch "$MOCK_STATE/nginx_bad"
setup_run "$R" install
check        "установка остановлена"                    test "$rc" -ne 0
expect_has   "сообщение и путь к бэкапу"                "$out" "Ошибка в конфиге nginx. Бэкап: $R/root/vrc-stream-backups/nginx-"

section "Удаление после установки"
R=$T_TMP/root-fresh; mock ufw fail2ban-client   # на этом сервере они установлены
reset_calls
setup_run "$R" uninstall
expect_eq    "успешно (код 0)"                          "$rc" "0"
check "сервис MediaMTX удалён"                          test ! -e "$R/etc/systemd/system/mediamtx.service"
check "таймер автосброса удалён"                        test ! -e "$R/etc/systemd/system/vrc-stream-heal.timer"
check "настройки удалены"                               test ! -e "$R/etc/vrc-stream"
check "команда vrc-stream удалена"                      test ! -e "$R/usr/local/bin/vrc-stream"
check "правила fail2ban удалены"                        test ! -e "$R/etc/fail2ban/jail.d/vrc-stream.conf"
expect_has   "пользователь mediamtx удалён (подставным userdel)" "$(calls)" "userdel mediamtx"
expect_has   "RTMP закрыт в ufw"                        "$(calls)" "ufw delete allow 1935/tcp"
expect_hasnt "80 остаётся открытым"                     "$(calls)" "ufw delete allow 80/tcp"
expect_hasnt "443 остаётся открытым"                    "$(calls)" "ufw delete allow 443/tcp"

finish

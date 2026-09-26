#!/usr/bin/env bash
# Генерация конфигов: MediaMTX, nginx, systemd — и профили OBS в репозитории
source "$(dirname "$0")/../lib.sh"
mock systemctl

# Системные действия (пользователь mediamtx, права, nginx -t) здесь не нужны
stubs() { id() { return 0; }; useradd() { :; }; install() { :; }; chown() { :; }; ln() { :; }; nginx() { return 0; }; }
gen() { (set -euo pipefail; stubs; load_settings; for kv in "$@"; do export "${kv?}"; done; load_settings
         STREAM_KEY=testkey12345; HLS_CDN_SECRET=0123456789abcdef01234567; write_mediamtx_config) 2>&1; }

section "Конфиг MediaMTX"
gen >/dev/null; c=$(cat "$MTX_CONF")
expect_has "OBS публикует только с ключом"        "$c" 'pass: "testkey12345"'
expect_has "смотреть могут все"                   "$c" "action: read"
expect_has "API только с localhost"               "$c" "apiAddress: 127.0.0.1:9997"
expect_has "HLS наружу только через nginx"        "$c" "hlsAddress: 127.0.0.1:8888"
expect_has "RTSP только TCP"                      "$c" "rtspTransports: [tcp]"
expect_has "простой HLS через CDN-секрет"         "$c" 'hlsCDNSecret: "0123456789abcdef01234567"'
expect_has "HLS mpegts по умолчанию"              "$c" "hlsVariant: mpegts"
expect_has "сегменты по 1 с"                      "$c" "hlsSegmentDuration: 1s"
expect_has "WebRTC/SRT/MoQ выключены"             "$c" "moq: false"
expect_has "заставка включена по умолчанию"       "$c" "alwaysAvailable: true"
expect_has "…с AAC 48 кГц"                        "$c" "sampleRate: 48000"
gen OFFLINE_SCREEN=0 HLS_SEGMENT=2s RTMP_PORT=1936 >/dev/null; c=$(cat "$MTX_CONF")
expect_hasnt "OFFLINE_SCREEN=0 — без заставки"    "$c" "alwaysAvailable"
expect_has   "HLS_SEGMENT применяется"            "$c" "hlsSegmentDuration: 2s"
expect_has   "RTMP_PORT применяется"              "$c" "rtmpAddress: :1936"

section "nginx"
ngx() { local cert=$2; (set -euo pipefail; stubs; load_settings; DOMAIN=$1; HLS_CDN_SECRET=0123456789abcdef01234567
         have_cert() { [[ $cert == yes ]]; }; write_nginx) >/dev/null 2>&1; }
ngx stream.example.com no
s=$(cat "$NGINX_SITE"); n=$(cat "$NGINX_SNIPPET")
expect_has   "HTTP на 80"                         "$s" "listen 80 default_server"
expect_hasnt "без сертификата — без 443"          "$s" "listen 443"
expect_has   "секрет MediaMTX добавляет nginx"    "$n" 'proxy_set_header Authorization "Bearer 0123456789abcdef01234567"'
expect_has   "проверка Let's Encrypt через 80"    "$n" "/.well-known/acme-challenge/"
expect_has   "/health для проверок"               "$n" "location = /health"
expect_has   "лог для подсчёта зрителей"          "$s" "log_format vrc_stream"
ngx stream.example.com yes
s=$(cat "$NGINX_SITE")
expect_has   "с сертификатом — HTTPS на 443"      "$s" "listen 443 ssl default_server"
expect_has   "…с путями Let's Encrypt"            "$s" "live/stream.example.com/fullchain.pem"

section "systemd"
(set -euo pipefail; write_mediamtx_service) >/dev/null 2>&1
u=$(cat "$SYSTEMD_DIR/mediamtx.service")
expect_has "MediaMTX не от root"                  "$u" "User=mediamtx"
expect_has "перезапуск при падении"               "$u" "Restart=always"
expect_has "изоляция файловой системы"            "$u" "ProtectSystem=strict"
echo '#!/bin/sh' > "$SELF_BIN"; chmod +x "$SELF_BIN"   # на Windows исполняемым считается файл с #!
(set -euo pipefail; write_heal_timer) >/dev/null 2>&1
expect_has "таймер автосброса раз в минуту"       "$(cat "$SYSTEMD_DIR/vrc-stream-heal.timer")" "OnUnitActiveSec=1min"
expect_has "…запускает vrc-stream heal"           "$(cat "$SYSTEMD_DIR/vrc-stream-heal.service")" "heal"

section "Профили OBS"
for d in "$T_ROOT"/obs-profiles/*/; do
  p=$(basename "$d"); ini=$(cat "$d/basic.ini")
  expect_has "$p: расширенный режим вывода"      "$ini" "Mode=Advanced"
  expect_has "$p: 48 кГц (нужно для заставки)"   "$ini" "SampleRate=48000"
  expect_has "$p: ограниченный цветовой диапазон" "$ini" "ColorRange=Partial"
  enc=$(jq -c . "$d/streamEncoder.json" 2>&1) || bad "$p: streamEncoder.json — корректный JSON" "$enc"
  expect_eq  "$p: ключевые кадры 1 с"            "$(jq -r .keyint_sec <<<"$enc")" "1"
  expect_eq  "$p: CBR"                           "$(jq -r '.rate_control | ascii_upcase' <<<"$enc")" "CBR"
  expect_eq  "$p: без B-кадров"                  "$(jq -r '(.bf // .bframes // 0)' <<<"$enc")" "0"
  expect_eq  "$p: service.json — свой RTMP"      "$(jq -r .type "$d/service.json")" "rtmp_custom"
done

finish

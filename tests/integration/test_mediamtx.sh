#!/usr/bin/env bash
# Настоящий MediaMTX с конфигом из setup.sh: ключ OBS, HLS, RTSP, заставка, status, автосброс.
# Второй экземпляр MediaMTX изображает OBS (публикует по RTMP), третий — зрителя по RTSP.
source "$(dirname "$0")/../lib.sh"
mock systemctl

MTX=${MEDIAMTX_BIN:-}
if [[ -z $MTX ]]; then
  MTX=$("$T_ROOT/tests/get-mediamtx.sh") || { bad "не удалось скачать MediaMTX"; finish; exit; }
fi

PIDS=()
declare -A PID=()
trap 'kill "${PIDS[@]}" 2>/dev/null; wait 2>/dev/null; rm -rf "$T_TMP"' EXIT
start() { # start имя конфиг
  "$MTX" "$2" > "$T_TMP/$1.log" 2>&1 &
  PIDS+=($!)
  PID[$1]=$!
}
wait_for() { local _; for _ in $(seq 1 60); do "$@" >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1; }

KEY=testkey12345
SECRET=0123456789abcdef01234567
api()     { curl -fsS --max-time 3 http://127.0.0.1:9997/v3/paths/list; }
path_is() { api | jq -e --arg p "$1" --arg f "$2" '.items[] | select(.name == $p) | .[$f] == true' >/dev/null; }
hls()     { curl -fsS --max-time 3 -H "Authorization: Bearer $SECRET" "http://127.0.0.1:8888/live/stream/$1"; }
media_pl() { hls "$(hls index.m3u8 | grep -v '^#' | grep -m1 .)"; }

# ---- сервер: конфиг генерирует сам setup.sh
(set -euo pipefail
 id() { return 0; }; useradd() { :; }; install() { :; }; chown() { :; }
 load_settings; STREAM_KEY=$KEY; HLS_CDN_SECRET=$SECRET; write_mediamtx_config)
start server "$MTX_CONF"

section "Запуск"
check "MediaMTX запустился с конфигом из setup.sh" wait_for api
expect_hasnt "конфиг без ошибок и предупреждений" "$(cat "$T_TMP/server.log")" "ERR"

section "Заставка без OBS"
check "поток доступен (заставка)"          wait_for path_is live/stream available
check "…но OBS не в эфире"                  not path_is live/stream online
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $SECRET" http://127.0.0.1:8888/live/stream/index.m3u8)
expect_eq "HLS через nginx-секрет: 200 без редиректа" "$code" "200"
code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8888/live/stream/index.m3u8)
expect_eq "без секрета — редирект с cookie (поэтому его добавляет nginx)" "$code" "302"

# ---- «OBS»: верный ключ; и две попытки без ключа / с чужим ключом
cat > "$T_TMP/obs.yml" <<EOF
logLevel: info
api: false
rtsp: false
rtmp: false
hls: false
webrtc: false
srt: false
moq: false
paths:
  src:
    alwaysAvailable: true
    alwaysAvailableTracks:
      - codec: H264
      - codec: MPEG4Audio
        sampleRate: 48000
        channelCount: 2
    forward:
      - dest: "rtmp://127.0.0.1:1935/live#stream?user=obs&pass=$KEY"
      - dest: "rtmp://127.0.0.1:1935/live#hacker?user=obs&pass=wrongkey12345"
      - dest: "rtmp://127.0.0.1:1935/live#anon"
EOF
start obs "$T_TMP/obs.yml"

section "Ключ OBS"
check "OBS с верным ключом в эфире"         wait_for path_is live/stream online
check "чужой ключ отклонён"                 wait_for grep -q "failed to authenticate" "$T_TMP/server.log"
check "путь с чужим ключом не создан"       not path_is live/hacker available
check "путь без ключа не создан"            not path_is live/anon available
check "отказ виден в логе для fail2ban"     grep -Eq 'WAR \[RTMP\] \[conn 127\.0\.0\.1:[0-9]+\] failed to authenticate: authentication failed' "$T_TMP/server.log"

section "HLS"
check "плейлист отдаётся"                   wait_for media_pl
pl=$(media_pl)
td=$(sed -n 's/^#EXT-X-TARGETDURATION://p' <<<"$pl")
check "TARGETDURATION ≤ 2 с (сегменты по 1 с)" test "${td:-99}" -le 2
seg=$(grep -v '^#' <<<"$pl" | grep . | tail -n 1)
hls "$seg" > "$T_TMP/seg.ts"
expect_eq "сегмент — MPEG-TS (байт 0x47)"   "$(od -An -tx1 -N1 "$T_TMP/seg.ts" | tr -d ' ')" "47"

section "RTSP"
rtsp() { exec 3<>/dev/tcp/127.0.0.1/8554; printf '%s\r\nCSeq: 1\r\n%s\r\n' "$1" "${2:+$2$'\r\n'}" >&3; timeout 3 cat <&3; exec 3<&-; }
out=$(rtsp "DESCRIBE rtsp://127.0.0.1:8554/live/stream RTSP/1.0")
expect_has "DESCRIBE: 200"                  "$out" "RTSP/1.0 200 OK"
expect_has "…видео H.264"                   "$out" "H264/90000"
expect_has "…аудио AAC 48 кГц"              "$out" "mpeg4-generic/48000/2"
out=$(rtsp "SETUP rtsp://127.0.0.1:8554/live/stream/trackID=0 RTSP/1.0" "Transport: RTP/AVP;unicast;client_port=40000-40001")
expect_has "UDP отклонён — только TCP"      "$out" "461 Unsupported Transport"

# ---- «зритель» по RTSP (TCP)
cat > "$T_TMP/viewer.yml" <<'EOF'
logLevel: warn
api: false
rtsp: false
rtmp: false
hls: false
webrtc: false
srt: false
moq: false
paths:
  view:
    source: rtsp://127.0.0.1:8554/live/stream
    rtspTransport: tcp
EOF
start viewer "$T_TMP/viewer.yml"
viewer_seen() { api | jq -e '[.items[].readers[]? | select(.type | test("^rtsp"))] | length > 0' >/dev/null; }

section "vrc-stream status"
check "зритель RTSP подключился" wait_for viewer_seen
out=$( (set -euo pipefail
        curl() { command curl -H "Authorization: Bearer $SECRET" "$@"; }
        HLS_CHECK_BASE=http://127.0.0.1:8888; load_settings; cmd_status) 2>&1 | strip_colors)
expect_has "сервисы работают"        "$out" "mediamtx: работает"
expect_has "эфир"                    "$out" "● В ЭФИРЕ"
expect_has "дорожки"                 "$out" "H264 1920x1080, MPEG-4 Audio 48000 Гц"
expect_has "битрейт от OBS"          "$out" "Кбит/с (входящий от OBS)"
expect_has "зритель RTSP посчитан"   "$out" "RTSP: 1"
expect_has "задержка HLS"            "$out" "задержка у зрителей ≈"

section "Автосброс на настоящем API"
reset_calls
(set -euo pipefail; curl() { command curl -H "Authorization: Bearer $SECRET" "$@"; }
 HLS_CHECK_BASE=http://127.0.0.1:8888; HEAL_STAMP=$T_TMP/heal.stamp; load_settings; cmd_heal) >/dev/null 2>&1
expect_hasnt "OBS в эфире — MediaMTX не трогает" "$(calls)" "restart mediamtx"

section "OBS отключился — заставка без разрыва"
before=$(media_pl)
prefix=$(grep -v '^#' <<<"$before" | grep -m1 . | sed 's/_seg.*//')
seq_before=$(sed -n 's/^#EXT-X-MEDIA-SEQUENCE://p' <<<"$before")
kill "${PID[obs]}" 2>/dev/null
check "OBS больше не в эфире"             wait_for not path_is live/stream online
check "поток по-прежнему доступен"        path_is live/stream available
sleep 3
after=$(media_pl)
expect_has "тот же HLS-поток (плееры не отключаются)" "$after" "${prefix}_seg"
check "нумерация сегментов продолжается"  test "$(sed -n 's/^#EXT-X-MEDIA-SEQUENCE://p' <<<"$after")" -gt "${seq_before:-0}"
out=$( (set -euo pipefail; curl() { command curl -H "Authorization: Bearer $SECRET" "$@"; }
        HLS_CHECK_BASE=http://127.0.0.1:8888; load_settings; cmd_status) 2>&1 | strip_colors)
expect_has "status: идёт заставка"        "$out" "OBS не подключён (идёт заставка)"
expect_hasnt "status: без битрейта OBS"   "$out" "входящий от OBS"

finish

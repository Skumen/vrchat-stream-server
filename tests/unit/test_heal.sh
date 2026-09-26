#!/usr/bin/env bash
# Задержка HLS: проверка в status и автосброс (vrc-stream heal)
source "$(dirname "$0")/../lib.sh"
mock systemctl
export HEAL_STAMP=$T_TMP/heal.stamp

# Подставные ответы: API MediaMTX (в формате v1.21) и HLS-плейлисты
fake_http() {
  curl() {
    case "$*" in
      *v3/paths/list*) printf '{"itemCount":1,"items":[{"name":"live/stream","ready":true,"available":true,"online":%s,"readers":%s,"inboundBytes":1}]}' "$ONLINE" "$READERS" ;;
      *index.m3u8*)    printf '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nmain_stream.m3u8\n' ;;
      *main_stream*)   printf '#EXTM3U\n#EXT-X-TARGETDURATION:%s\n' "$TD"; for d in $SEGS; do printf '#EXTINF:%s,\na.ts\n' "$d"; done ;;
    esac
  }
  hls_viewers() { echo "${VIEWERS:-0}"; }
}

heal() { # heal online readers viewers targetduration
  reset_calls
  (set -euo pipefail; fake_http; ONLINE=$1 READERS=$2 VIEWERS=$3 TD=$4 SEGS="1.0 1.0"; load_settings; cmd_heal) 2>&1
}
restarted() { calls | grep -q "systemctl restart mediamtx"; }

section "Автосброс: перезапуск только когда никто не смотрит"
rm -f "$HEAL_STAMP"
heal true  '[]' 0 5 >/dev/null;                                   check "OBS в эфире — не трогает"            not restarted
heal false '[{"type":"rtspSession","id":"x"}]' 0 5 >/dev/null;   check "есть зритель RTSP — не трогает"      not restarted
heal false '[{"type":"rtmpConn","id":"x"}]' 0 5 >/dev/null;      check "есть зритель RTMP — не трогает"      not restarted
heal false '[{"type":"hlsSession","id":"cdn"}]' 2 5 >/dev/null;  check "есть зрители HLS — не трогает"       not restarted
heal false '[]' 0 1 >/dev/null;                                   check "задержка в норме — не трогает"       not restarted
out=$(heal false '[{"type":"hlsSession","id":"cdn"}]' 0 5);      check "никого, TD=5 → перезапуск MediaMTX"  restarted
expect_has "пишет причину в журнал" "$out" "TARGETDURATION 5 с > 1 с"
heal false '[]' 0 5 >/dev/null;                                   check "повтор раньше 10 мин — пропуск"      not restarted
touch -d '11 minutes ago' "$HEAL_STAMP"
heal false '[]' 0 5 >/dev/null;                                   check "через 11 мин — снова перезапуск"     restarted
out=$( (set -euo pipefail; fake_http; ONLINE=false READERS='[]' TD=5 SEGS=1.0; HLS_SEGMENT=2s; load_settings; cmd_heal) 2>&1)
check "HLS_SEGMENT=2s: TD=5 всё равно больше" restarted
reset_calls
(set -euo pipefail; curl() { return 7; }; load_settings; cmd_heal) >/dev/null 2>&1; rc=$?
expect_eq "MediaMTX недоступен — тихо выходит (код 0)" "$rc" "0"

section "Проверка задержки в status"
lat() { # lat live targetduration "длины сегментов"
  (set -euo pipefail; fake_http; ONLINE=true READERS='[]'; TD=$2; SEGS=$3; load_settings; hls_latency_check "$1") 2>&1 | strip_colors
}
out=$(lat true 1 "1.0 1.0 1.0")
expect_has   "норма: задержка ≈ 3 с"           "$out" "TARGETDURATION 1 с → задержка у зрителей ≈ 3 с"
expect_hasnt "норма: без предупреждений"       "$out" "[!]"
out=$(lat true 5 "4.16667 4.16667")
expect_has   "длинные сегменты в эфире → совет про OBS" "$out" "интервал ключевых кадров должен быть 1 s"
out=$(lat false 5 "1.0 1.0")
expect_has   "TD вырос → объясняет"            "$out" "TARGETDURATION вырос до 5 с"
expect_has   "…и что сбросится сам"            "$out" "Сбросится сам"
out=$( (set -euo pipefail; curl() { return 7; }; load_settings; hls_latency_check true) 2>&1); rc=$?
expect_eq "плейлист недоступен — без ошибки" "$rc" "0"

finish

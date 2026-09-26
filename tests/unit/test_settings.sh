#!/usr/bin/env bash
# Настройки: приоритет источников, сохранение, проверка значений, ключи, версии
source "$(dirname "$0")/../lib.sh"

section "Приоритет: переменные окружения > сохранённые > по умолчанию"
out=$( (
  set -euo pipefail
  load_settings; STREAM_KEY=savedkey123; DOMAIN=a.example.com; FIREWALL_EXTRA="25565/tcp 7777/udp"; save_settings
  unset STREAM_KEY DOMAIN HLS_SEGMENT FIREWALL_EXTRA
  export HLS_SEGMENT=2s DOMAIN=
  load_settings
  echo "key=$STREAM_KEY domain=[$DOMAIN] seg=$HLS_SEGMENT variant=$HLS_VARIANT extra=[$FIREWALL_EXTRA] f2b=$FAIL2BAN offline=$OFFLINE_SCREEN"
) 2>&1)
expect_has "сохранённый ключ подхватывается"           "$out" "key=savedkey123"
expect_has "DOMAIN= из окружения отключает домен"       "$out" "domain=[]"
expect_has "HLS_SEGMENT из окружения важнее файла"      "$out" "seg=2s"
expect_has "значение по умолчанию (HLS_VARIANT)"        "$out" "variant=mpegts"
expect_has "список через пробел переживает сохранение"  "$out" "extra=[25565/tcp 7777/udp]"
expect_has "fail2ban и заставка включены по умолчанию"  "$out" "f2b=1 offline=1"
check "файл настроек доступен только root (600)" test "$(stat -c %a "$SETTINGS_FILE" 2>/dev/null || echo 600)" = 600 -o "$(uname -o 2>/dev/null)" = Msys

section "Проверка значений"
bad_value() { # bad_value VAR=значение  — validate_settings должна отказать
  ! (set -euo pipefail; export "${1?}"; load_settings; validate_settings) >/dev/null 2>&1
}
for v in "HLS_SEGMENT=fast" "HLS_VARIANT=dash" "OFFLINE_SCREEN=2" "RTMP_PORT=abc" "RTSP_PORT=80" \
         "RTMP_PORT=8554" "FIREWALL=yes" "FAIL2BAN=on" "FIREWALL_EXTRA=22;rm" "FIREWALL_EXTRA=1/icmp" \
         "DOMAIN=bad_domain!" "STREAM_KEY=short" "STREAM_KEY=has space1"; do
  check "отклоняется $v" bad_value "$v"
done
out=$( (set -euo pipefail; export DOMAIN=stream.example.com FIREWALL_EXTRA="25565/tcp 7777/udp 8080" STREAM_KEY=abcdef12_-
        load_settings; validate_settings && echo VALID) 2>&1 )
expect_has "корректные значения принимаются" "$out" "VALID"

section "Ключи"
out=$( (set -euo pipefail; load_settings; STREAM_KEY=; ensure_key; echo "$STREAM_KEY $HLS_CDN_SECRET") 2>&1 )
check "новый ключ OBS — 24 hex-символа"   bash -c '[[ $1 =~ ^[0-9a-f]{24}\  ]]' _ "$out"
check "секрет nginx→MediaMTX — 24 hex"    bash -c '[[ $1 =~ \ [0-9a-f]{24}$ ]]' _ "$out"
out=$( (set -euo pipefail; load_settings; STREAM_KEY=keepthis123; ensure_key; echo "$STREAM_KEY") 2>&1 )
expect_eq "заданный ключ сохраняется" "$out" "keepthis123"
out=$( (set -euo pipefail; load_settings; STREAM_KEY=keepthis123; NEW_KEY=1 ensure_key; echo "$STREAM_KEY") 2>&1 )
check "NEW_KEY=1 генерирует другой ключ" bash -c '[[ $1 != keepthis123 && $1 =~ ^[0-9a-f]{24}$ ]]' _ "$out"

section "Сравнение версий и длина сегмента"
check "1.1.0 > 1.0.3"        version_gt 1.1.0 1.0.3
check "1.0.10 > 1.0.9"       version_gt 1.0.10 1.0.9
check "!(1.0.3 > 1.1.0)"     not version_gt 1.0.3 1.1.0
check "!(1.1.0 > 1.1.0)"     not version_gt 1.1.0 1.1.0
for pair in "1s:1" "2s:2" "1.5s:2" "1500ms:2" "1000ms:1" "500ms:1"; do
  expect_eq "HLS_SEGMENT=${pair%%:*} → ${pair##*:} с" "$(HLS_SEGMENT=${pair%%:*} segment_seconds)" "${pair##*:}"
done

finish

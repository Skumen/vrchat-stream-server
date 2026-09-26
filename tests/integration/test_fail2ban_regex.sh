#!/usr/bin/env bash
# Фильтр fail2ban из setup.sh на реальных строках лога MediaMTX (настоящий fail2ban-regex)
source "$(dirname "$0")/../lib.sh"

if ! command -v fail2ban-regex >/dev/null; then
  if [[ -n ${CI:-} ]]; then
    bad "fail2ban-regex не установлен"
  else
    echo "  – fail2ban-regex не установлен, пропускаю (в GitHub Actions проверяется)"
  fi
  finish; exit
fi

(set -euo pipefail; write_fail2ban_filter)
out=$(fail2ban-regex "$T_ROOT/tests/fixtures/mediamtx-auth.log" "$F2B_FILTER" 2>&1)
matched=$(grep -Eo '[0-9]+ matched' <<<"$out" | head -n 1 | cut -d' ' -f1)

section "Фильтр vrc-stream-mediamtx"
expect_eq  "ловит 3 неудачные попытки (IPv4, IPv4, IPv6)" "${matched:-нет}" "3"
expect_has "IP атакующего по RTMP"      "$out" "203.0.113.7"
expect_has "второй IP"                  "$out" "198.51.100.9"
expect_has "IPv6"                       "$out" "2001:db8::5"
expect_hasnt "не трогает успешную публикацию" "$(grep -A50 'Addresses found' <<<"$out")" "192.0.2.10"

finish

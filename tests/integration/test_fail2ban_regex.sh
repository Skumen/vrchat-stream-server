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
log=$T_ROOT/tests/fixtures/mediamtx-auth.log
out=$(fail2ban-regex "$log" "$F2B_FILTER" 2>&1)
matched=$(grep -Eo '[0-9]+ matched' <<<"$out" | head -n 1 | cut -d' ' -f1)
# --out ip — ровно те адреса, которые fail2ban забанит
ips=$(fail2ban-regex --out ip "$log" "$F2B_FILTER" 2>&1 | sort -u | tr '\n' ' ')

section "Фильтр vrc-stream-mediamtx"
expect_eq  "ловит 3 неудачные попытки, «closed:» не считает дважды" "${matched:-нет}" "3"
expect_eq  "банит ровно эти IP (IPv4, IPv4, IPv6)" "$ips" "198.51.100.9 2001:db8::5 203.0.113.7 "
expect_hasnt "не трогает успешную публикацию"      "$ips" "192.0.2.10"
expect_hasnt "не трогает обычные отключения"       "$ips" "192.0.2.20"

finish

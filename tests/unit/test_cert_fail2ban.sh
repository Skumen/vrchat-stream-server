#!/usr/bin/env bash
# Срок сертификата в status и fail2ban: установка, правила, статус, разбан
source "$(dirname "$0")/../lib.sh"
mock systemctl apt-get pgrep

section "Срок сертификата"
make_cert() { # make_cert домен дней
  mkdir -p "$LE_LIVE/$1"
  MSYS2_ARG_CONV_EXCL="/CN" openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T_TMP/key.pem" \
    -out "$LE_LIVE/$1/fullchain.pem" -days "$2" -subj "/CN=$1" >/dev/null 2>&1
}
make_cert ok.example.com 60
make_cert old.example.com 10
cert() { (set -euo pipefail; load_settings; DOMAIN=$1; cert_status) 2>&1 | strip_colors; }
out=$(cert ok.example.com)
expect_has   "показывает срок"                 "$out" "действует ещё 59 дн."
expect_hasnt "60 дней — без предупреждения"    "$out" "не продлился"
out=$(cert old.example.com)
expect_has   "10 дней — предупреждение"        "$out" "не продлился вовремя"
expect_has   "…с командой проверки"            "$out" "certbot renew --dry-run"
expect_has   "нет сертификата — так и пишет"   "$(cert missing.example.com)" "не найден"
expect_eq    "без домена — ничего не пишет"    "$(cert '')" ""

section "fail2ban: установка и правила"
f2b() { (set -euo pipefail; load_settings; for kv in "$@"; do export "${kv?}"; done; load_settings; setup_fail2ban) 2>&1 | strip_colors; }
unmock fail2ban-client ufw; rm -f "$MOCK_STATE/ufw_active"; reset_calls
out=$(f2b)
expect_has "ставится с python3-systemd"          "$(calls)" "install -y -q fail2ban python3-systemd"
expect_has "jail читает журнал MediaMTX"         "$(cat "$F2B_JAIL")" "journalmatch = _SYSTEMD_UNIT=mediamtx.service"
expect_has "мягкое правило: 20 попыток"          "$(cat "$F2B_JAIL")" "maxretry     = 20"
expect_has "бан на 30 минут"                     "$(cat "$F2B_JAIL")" "bantime      = 30m"
expect_has "порты RTMP и RTSP"                   "$(cat "$F2B_JAIL")" "port         = 1935,8554"
expect_has "без ufw — iptables/nftables"         "$(cat "$F2B_JAIL")" "multiport"
expect_has "SSH-jail переведён на journald"      "$(cat "$F2B_SSHD")" "backend = systemd"
expect_has "фильтр ловит неверный ключ"          "$(cat "$F2B_FILTER")" 'failed to authenticate: authentication failed'
expect_has "fail2ban перезапущен"                "$(calls)" "systemctl restart fail2ban"
expect_has "сообщение об успехе"                 "$out" "бан после 20 неудачных попыток"

mock ufw; touch "$MOCK_STATE/ufw_active"
f2b >/dev/null
expect_has "с включённым ufw — бан через ufw"    "$(cat "$F2B_JAIL")" "banaction    = ufw"

section "fail2ban: выключение и сбои"
out=$(f2b FAIL2BAN=0)
check      "FAIL2BAN=0 удаляет правила vrc-stream" test ! -f "$F2B_JAIL" -a ! -f "$F2B_FILTER"
expect_has "…и сообщает об этом"                  "$out" "FAIL2BAN=0"
unmock fail2ban-client; touch "$MOCK_STATE/apt_fail"
out=$(f2b); rc=$?
rm -f "$MOCK_STATE/apt_fail"
expect_eq  "не установился — установка продолжается" "$rc" "0"
expect_has "…с предупреждением"                    "$out" "Не удалось установить fail2ban"

section "fail2ban: status и разбан"
mock fail2ban-client
echo "" > "$MOCK_STATE/f2b_banned"
expect_has "нет банов"            "$(fail2ban_status)" "заблокированных IP нет"
echo "203.0.113.7 198.51.100.9" > "$MOCK_STATE/f2b_banned"
out=$(fail2ban_status)
expect_has "число банов"          "$out" "заблокировано IP: 2"
expect_has "список IP"            "$out" "203.0.113.7 198.51.100.9"
reset_calls
out=$( (set -euo pipefail; cmd_unban 203.0.113.7) 2>&1 | strip_colors)
expect_has "unban <IP>"           "$(calls)" "set vrc-stream unbanip 203.0.113.7"
expect_has "…подтверждение"       "$out" "IP 203.0.113.7 разбанен"
out=$( (set -euo pipefail; cmd_unban all) 2>&1 | strip_colors)
expect_has "unban all"            "$(calls)" "unban --all"
out=$( (set -euo pipefail; cmd_unban '1.2.3.4;reboot') 2>&1); rc=$?
check      "мусор вместо IP отклоняется" test "$rc" -ne 0
out=$( (set -euo pipefail; cmd_unban) 2>&1); rc=$?
check      "без IP — подсказка и ошибка" test "$rc" -ne 0
touch "$MOCK_STATE/f2b_down"
out=$( (set -euo pipefail; cmd_unban 203.0.113.7) 2>&1 | strip_colors); rc=${PIPESTATUS[0]}
rm -f "$MOCK_STATE/f2b_down"
expect_has "fail2ban не отвечает — понятная ошибка" "$out" "fail2ban не ответил"

finish

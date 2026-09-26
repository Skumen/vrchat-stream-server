#!/usr/bin/env bash
# Фаервол ufw: установка, SSH до включения, 80/443 всегда открыты, удаление правил
source "$(dirname "$0")/../lib.sh"
mock apt-get ss sshd pgrep
export MOCK_SSHD_PORT=2222 SSH_CONNECTION="10.0.0.5 51000 10.0.0.1 2222"

fw() { # fw [переменные...] — setup_firewall с RTMP/RTSP по умолчанию
  (set -euo pipefail; load_settings; for kv in "$@"; do export "${kv?}"; done; load_settings; setup_firewall) 2>&1 | strip_colors
}
line_of() { calls | grep -n -- "$1" | head -n 1 | cut -d: -f1; }

section "ufw не установлен"
unmock ufw; rm -f "$MOCK_STATE/ufw_active"; reset_calls
out=$(fw)
expect_has "ставится через apt"                 "$(calls)" "install -y -q ufw"
expect_has "порт SSH из sshd и подключения"      "$(calls)" "allow 2222/tcp comment SSH"
expect_has "22 разрешается всегда"               "$(calls)" "allow 22/tcp comment SSH"
check      "SSH разрешён ДО включения ufw"       test "$(line_of 'allow 22/tcp')" -lt "$(line_of -- '--force enable')"
expect_has "80 открыт (Let's Encrypt)"           "$(calls)" "allow 80/tcp"
expect_has "443 открыт"                          "$(calls)" "allow 443/tcp"
expect_has "RTMP 1935 открыт"                    "$(calls)" "allow 1935/tcp"
expect_has "RTSP 8554 открыт"                    "$(calls)" "allow 8554/tcp"
expect_has "по умолчанию входящее закрыто"       "$(calls)" "default deny incoming"
expect_has "предупреждение о закрытых портах"    "$out" "25565/tcp 7777/udp"
expect_hasnt "localhost-порты не в списке"       "$out" "8888"
expect_hasnt "DHCP-клиент (68/udp) не в списке"  "$out" "68/udp"
expect_has "подсказка FIREWALL_EXTRA"            "$out" 'FIREWALL_EXTRA="25565/tcp 7777/udp"'

section "ufw установлен и уже включён"
touch "$MOCK_STATE/ufw_active"; reset_calls
out=$(fw)
expect_hasnt "не переустанавливается"            "$(calls)" "apt-get"
expect_hasnt "не включается повторно"            "$(calls)" "--force enable"
expect_hasnt "политика по умолчанию не меняется" "$(calls)" "default deny"
expect_has   "правила добавляются"               "$(calls)" "allow 80/tcp"
expect_has   "сообщение «уже включён»"           "$out" "ufw уже включён"

section "ufw выключен + FIREWALL_EXTRA"
rm -f "$MOCK_STATE/ufw_active"; reset_calls
out=$(fw FIREWALL_EXTRA="25565/tcp 7777/udp")
expect_has   "доп. порт TCP открыт"              "$(calls)" "allow 25565/tcp"
expect_has   "доп. порт UDP открыт"              "$(calls)" "allow 7777/udp"
expect_hasnt "открытые порты не в предупреждении" "$out" "закрыты фаерволом"
expect_has   "ufw включён"                       "$(calls)" "--force enable"

section "FIREWALL=0"
reset_calls
out=$(fw FIREWALL=0)
expect_eq  "ufw не вызывается" "$(calls)" ""
expect_has "сообщение о пропуске" "$out" "FIREWALL=0"

section "ufw не устанавливается (apt упал)"
unmock ufw; rm -f "$MOCK_STATE/ufw_active"; touch "$MOCK_STATE/apt_fail"; reset_calls
out=$(fw); rc=$?
rm -f "$MOCK_STATE/apt_fail"
expect_eq  "установка не прерывается (код 0)" "$rc" "0"
expect_has "предупреждение"                    "$out" "Не удалось установить ufw"

section "Удаление правил (uninstall)"
mock ufw; reset_calls
(set -euo pipefail; load_settings; FIREWALL_EXTRA="25565/tcp"; remove_firewall_rules)
expect_has   "RTMP закрывается"        "$(calls)" "delete allow 1935/tcp"
expect_has   "RTSP закрывается"        "$(calls)" "delete allow 8554/tcp"
expect_has   "доп. порт закрывается"   "$(calls)" "delete allow 25565/tcp"
expect_hasnt "80 остаётся открытым"    "$(calls)" "delete allow 80/tcp"
expect_hasnt "443 остаётся открытым"   "$(calls)" "delete allow 443/tcp"
expect_hasnt "SSH остаётся открытым"   "$(calls)" "delete allow 22/tcp"

finish

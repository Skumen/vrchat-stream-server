#!/usr/bin/env bash
# Ожидание apt: свежая VM ставит обновления в фоне и держит блокировку
source "$(dirname "$0")/../lib.sh"
mock apt-get pgrep

apt_run() { (set -euo pipefail; sleep() { :; }; apt_get "$@") 2>&1 | strip_colors; }

section "apt свободен"
echo 0 > "$MOCK_STATE/apt_busy"; reset_calls
out=$(apt_run install -y -q ufw)
expect_eq  "без ожидания и сообщений"         "$out" ""
expect_has "apt-get ждёт блокировку dpkg сам" "$(calls)" "apt-get -o DPkg::Lock::Timeout=900 install -y -q ufw"

section "apt занят 3 проверки (15 с), потом свободен"
echo 3 > "$MOCK_STATE/apt_busy"; reset_calls
out=$(apt_run install -y -q ufw); rc=$?
expect_eq  "успех"                           "$rc" "0"
expect_has "говорит, кто занял apt"          "$out" "apt занят: unattended-upgr"
expect_has "apt-get запускается после ожидания" "$(calls)" "install -y -q ufw"

section "apt занят 1 минуту — прогресс раз в 30 с"
echo 13 > "$MOCK_STATE/apt_busy"; reset_calls
out=$(apt_run update -q)
expect_has "сообщение на 0:30" "$out" "всё ещё жду: 0:30"
expect_has "сообщение на 1:00" "$out" "всё ещё жду: 1:00"
expect_eq  "не чаще раза в 30 с" "$(grep -c 'всё ещё жду' <<<"$out")" "2"

section "apt занят дольше лимита"
echo 999 > "$MOCK_STATE/apt_busy"; reset_calls
out=$(APT_WAIT_MAX=60 apt_run update -q); rc=$?
check      "ошибка"                      test "$rc" -ne 0
expect_has "понятное сообщение"          "$out" "Запустите скрипт ещё раз"
expect_eq  "apt-get не запускался"       "$(calls)" ""

finish

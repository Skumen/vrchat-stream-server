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
expect_has "говорит, кто занял apt"          "$out" "apt занят: unattended-upgrade"
expect_has "apt-get запускается после ожидания" "$(calls)" "install -y -q ufw"

section "apt занят 1 минуту — прогресс раз в 30 с"
echo 13 > "$MOCK_STATE/apt_busy"; reset_calls
DPKG_LOG=$T_TMP/dpkg.log
echo "2026-09-26 16:40:01 unpack linux-firmware:all 20240318.git3b128b60-0ubuntu2.4" > "$DPKG_LOG"
out=$(apt_run update -q)
expect_has "показывает, что dpkg делает сейчас" "$out" "dpkg: 16:40:01 unpack linux-firmware:all"
expect_has "сообщение на 0:30" "$out" "всё ещё жду: 0:30"
expect_has "сообщение на 1:00" "$out" "всё ещё жду: 1:00"
expect_eq  "не чаще раза в 30 с" "$(grep -c 'всё ещё жду' <<<"$out")" "2"

section "apt занят дольше лимита"
echo 999 > "$MOCK_STATE/apt_busy"; reset_calls
out=$(APT_WAIT_MAX=60 apt_run update -q); rc=$?
check      "ошибка"                      test "$rc" -ne 0
expect_has "понятное сообщение"          "$out" "Запустите скрипт ещё раз"
expect_eq  "apt-get не запускался"       "$(calls)" ""

section "Настоящие процессы: служба unattended-upgrade-shutdown — не установка"
# Регрессия 1.1.0: pgrep по имени "unattended-upgr" ловил и службу ожидания выключения,
# которая работает всегда, — скрипт ждал 15 минут и падал
if [[ $(uname -s) == Linux ]] && command -v pgrep >/dev/null; then
  unmock pgrep
  fake=$T_TMP/fake
  mkdir -p "$fake/usr/share/unattended-upgrades" "$fake/usr/bin"
  # Процесс-оболочка живёт, пока идёт sleep, — с той же командной строкой, что у настоящих
  for f in "$fake/usr/share/unattended-upgrades/unattended-upgrade-shutdown" "$fake/usr/bin/unattended-upgrade"; do
    printf '%s\n' '#!/bin/sh' 'sleep 30' > "$f"
    chmod +x "$f"
  done

  "$fake/usr/share/unattended-upgrades/unattended-upgrade-shutdown" --wait-for-signal & helper=$!
  sleep 0.5
  expect_hasnt "служба ожидания выключения не держит apt" "$(apt_busy)" "unattended"
  "$fake/usr/bin/unattended-upgrade" & upgrade=$!
  sleep 0.5
  expect_has   "настоящая установка обновлений — держит"  "$(apt_busy)" "unattended-upgrade"
  pkill -P "$helper" 2>/dev/null; pkill -P "$upgrade" 2>/dev/null
  kill "$helper" "$upgrade" 2>/dev/null; wait 2>/dev/null
else
  echo "  – пропускаю: нужен Linux с pgrep (проверяется в GitHub Actions)"
fi

finish

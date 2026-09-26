#!/usr/bin/env bash
# Неожиданная ошибка: сообщение с командой вместо молчаливого выхода
source "$(dirname "$0")/../lib.sh"

section "Сообщение о неожиданной ошибке"
# Отдельный bash — как при настоящем запуске (обработчик срабатывает только на верхнем уровне)
out=$(VRC_STREAM_TEST=1 bash -c '
  source "$1"
  set -eE; trap '\''on_error $? $LINENO "$BASH_COMMAND"'\'' ERR
  broken() { local x; x=$(false); echo "не должно выполниться"; }
  broken
' _ "$T_ROOT/setup.sh" 2>&1 | strip_colors); rc=${PIPESTATUS[0]}
check        "скрипт останавливается"             test "$rc" -ne 0
expect_has   "пишет, что случилось"               "$out" "Неожиданная ошибка (код 1)"
expect_has   "…и на какой команде"                "$out" 'x=$(false)'
expect_has   "…и куда сообщить"                   "$out" "/issues"
expect_hasnt "дальше не выполняется"              "$out" "не должно выполниться"

out=$(VRC_STREAM_TEST=1 bash -c '
  source "$1"
  set -eE; trap '\''on_error $? $LINENO "$BASH_COMMAND"'\'' ERR
  v=$( { false; true; } ); if ! grep -q x <<<"y"; then :; fi; echo "OK"
' _ "$T_ROOT/setup.sh" 2>&1 | strip_colors)
expect_eq    "обработанные ошибки не шумят"       "$out" "OK"

finish

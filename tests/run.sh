#!/usr/bin/env bash
# Запуск тестов:  tests/run.sh [unit|integration|all]
#
# unit         — логика setup.sh на подставных командах, ~10 секунд, ничего не меняет в системе
# integration  — настоящий MediaMTX (MEDIAMTX_BIN или tests/get-mediamtx.sh) и fail2ban-regex
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

suite=${1:-all}
files=()
case $suite in
  unit)        files=(tests/unit/*.sh) ;;
  integration) files=(tests/integration/*.sh) ;;
  all)         files=(tests/unit/*.sh tests/integration/*.sh) ;;
  *)           echo "Использование: tests/run.sh [unit|integration|all]" >&2; exit 2 ;;
esac

failed=()
for f in "${files[@]}"; do
  printf '\n━━━ %s\n' "$f"
  bash "$f" || failed+=("$f")
done

echo
if (( ${#failed[@]} )); then
  printf '\033[31mПровалено файлов: %d\033[0m\n' "${#failed[@]}"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
printf '\033[32mВсе тесты пройдены (%d файлов)\033[0m\n' "${#files[@]}"

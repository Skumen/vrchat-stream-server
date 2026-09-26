#!/usr/bin/env bash
# vrc-stream update: проверка версии, скачивание, контрольная сумма, установка
source "$(dirname "$0")/../lib.sh"

# Подставной GitHub: релиз $LATEST, файлы из $T_TMP/gh/<тег>/
GH=$T_TMP/gh
publish() { # publish тег содержимое-setup.sh [испортить-сумму]
  mkdir -p "$GH/$1"
  printf '%s\n' "$2" > "$GH/$1/setup.sh"
  (cd "$GH/$1" && sha256sum setup.sh > SHA256SUMS.txt)
  [[ -n ${3:-} ]] && echo "0000000000000000000000000000000000000000000000000000000000000000  setup.sh" > "$GH/$1/SHA256SUMS.txt"
  return 0
}
fake_github() {
  curl() {
    local url=${*: -1} out=""
    while (( $# )); do [[ $1 == -o ]] && out=$2; shift; done
    case $url in
      *api.github.com*/releases/latest)
        [[ -n ${LATEST:-} ]] || return 22
        printf '{"tag_name":"%s"}' "$LATEST" ;;
      */releases/download/*)
        local tag=${url%/*}; tag=${tag##*/}
        [[ -f $GH/$tag/${url##*/} ]] || return 22
        cp "$GH/$tag/${url##*/}" "$out" ;;
      *) return 22 ;;
    esac
  }
  exec() { echo "EXEC $*"; }   # вместо запуска установки — только показать команду
}
upd() { (set -euo pipefail; fake_github; VRC_STREAM_VERSION=$1; shift; cmd_update "$@") 2>&1 | strip_colors; }

publish v1.2.0 'echo new-version-1.2.0'
publish v1.0.3 'echo old-version-1.0.3'

section "Проверка версии"
out=$(LATEST=v1.1.0 upd 1.1.0)
expect_has "последняя уже стоит"             "$out" "Установлена последняя версия: 1.1.0"
out=$(LATEST=v1.0.3 upd 1.1.0)
expect_has "стоит новее релиза — не трогает" "$out" "новее последнего релиза"
out=$(LATEST=v1.2.0 upd 1.1.0 --check)
expect_has "--check: есть новая"             "$out" "Доступна версия 1.2.0 (установлена 1.1.0)"
expect_has "--check: ссылка на релиз"        "$out" "releases/tag/v1.2.0"
expect_hasnt "--check: ничего не ставит"     "$out" "EXEC"
out=$(LATEST='' upd 1.1.0); rc=$?
check      "GitHub недоступен — ошибка"      test "$rc" -ne 0
expect_has "…с понятным текстом"             "$out" "нет доступа к GitHub"

section "Обновление"
out=$(LATEST=v1.2.0 upd 1.1.0)
expect_has "сумма проверена"                 "$out" "Файл проверен"
expect_has "запускает install новой версии"  "$out" "EXEC bash"
expect_has "…именно install"                 "$out" "setup.sh install"
out=$(upd 1.1.0 v1.0.3)
expect_has "конкретная версия (откат)"       "$out" "EXEC bash"
out=$(upd 1.1.0 1.0.3)
expect_has "версия без «v» тоже работает"    "$out" "EXEC bash"

section "Защита"
publish v1.3.0 'echo tampered' broken-sum
out=$(upd 1.1.0 v1.3.0); rc=$?
check      "подменённый файл — отказ"        test "$rc" -ne 0
expect_has "…контрольная сумма"              "$out" "Контрольная сумма setup.sh не совпала"
expect_hasnt "…и ничего не запущено"         "$out" "EXEC"
publish v1.4.0 'if then fi ((('
out=$(upd 1.1.0 v1.4.0); rc=$?
check      "битый скрипт — отказ"            test "$rc" -ne 0
expect_has "…с объяснением"                  "$out" "повреждён"
out=$(upd 1.1.0 v9.9.9); rc=$?
check      "нет такой версии — отказ"        test "$rc" -ne 0
out=$(upd 1.1.0 'latest;rm'); rc=$?
check      "мусор вместо версии — отказ"     test "$rc" -ne 0
expect_has "…с подсказкой формата"           "$out" "пример: v1.1.0"

finish

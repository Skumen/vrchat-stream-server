# Общие функции тестов: подключается из tests/unit/*.sh и tests/integration/*.sh.
# Загружает функции setup.sh (VRC_STREAM_TEST=1 — без запуска main) и перенаправляет
# все системные пути во временную папку, так что тесты ничего не меняют в системе.

T_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T_TMP=$(mktemp -d)
trap 'rm -rf "$T_TMP"' EXIT
T_PASS=0
T_FAIL=0

# ---- подставные команды (tests/mocks): по умолчанию в PATH нет ни одной, см. mock()
export MOCK_DIR=$T_ROOT/tests/mocks
export MOCK_BIN=$T_TMP/bin
export MOCK_LOG=$T_TMP/calls.log
export MOCK_STATE=$T_TMP/state
mkdir -p "$MOCK_BIN" "$MOCK_STATE"
: > "$MOCK_LOG"
export PATH="$MOCK_BIN:$PATH"

mock()   { local m; for m in "$@"; do cp "$MOCK_DIR/$m" "$MOCK_BIN/$m"; chmod +x "$MOCK_BIN/$m"; done; }
unmock() { local m; for m in "$@"; do rm -f "$MOCK_BIN/$m"; done; }
calls()  { cat "$MOCK_LOG"; }
reset_calls() { : > "$MOCK_LOG"; }

# ---- setup.sh
# shellcheck source=../setup.sh
VRC_STREAM_TEST=1 source "$T_ROOT/setup.sh"
set +e -uo pipefail

SETTINGS_DIR=$T_TMP/etc-vrc-stream
SETTINGS_FILE=$SETTINGS_DIR/settings.env
SYSTEMD_DIR=$T_TMP/systemd
F2B_JAIL=$T_TMP/f2b/jail.d/vrc-stream.conf
F2B_SSHD=$T_TMP/f2b/jail.d/vrc-stream-sshd.conf
F2B_FILTER=$T_TMP/f2b/filter.d/vrc-stream-mediamtx.conf
LE_LIVE=$T_TMP/letsencrypt/live
MTX_CONF=$T_TMP/mediamtx/mediamtx.yml
NGINX_SITE=$T_TMP/nginx/vrc-stream.conf
NGINX_SNIPPET=$T_TMP/nginx/snippet.conf
ACME_ROOT=$T_TMP/acme
SELF_BIN=$T_TMP/vrc-stream
mkdir -p "$SYSTEMD_DIR" "$(dirname "$MTX_CONF")" "$(dirname "$NGINX_SITE")"

# Git Bash на Windows не умеет менять права и владельца — игнорируем -m/-o/-g (на Linux всё как в бою)
if [[ $(uname -o 2>/dev/null) == Msys ]]; then
  install() {
    local a=()
    while (( $# )); do
      case $1 in -m|-o|-g) shift 2 ;; *) a+=("$1"); shift ;; esac
    done
    command install "${a[@]}"
  }
  chmod() { command chmod "$@" 2>/dev/null || true; }
fi

# Функцию setup.sh — в подоболочке с теми же строгими правилами (set -e), что и в бою
run() { ( set -euo pipefail; "$@" ); }
strip_colors() { sed 's/\x1b\[[0-9;]*m//g'; }

# ---- проверки
ok()  { T_PASS=$((T_PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() {
  T_FAIL=$((T_FAIL + 1)); printf '  \033[31m✗ %s\033[0m\n' "$1"
  if [[ -n ${2:-} ]]; then printf '%s\n' "$2" | sed 's/^/      │ /'; fi
}
section() { printf '\n%s\n' "$*"; }

# check "описание" команда…  — успех, если команда вернула 0
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
not()   { ! "$@"; }
# expect_has "описание" "$вывод" "подстрока"
expect_has()   { if [[ $2 == *"$3"* ]]; then ok "$1"; else bad "$1" "ожидалось «$3» в:"$'\n'"$2"; fi; }
expect_hasnt() { if [[ $2 != *"$3"* ]]; then ok "$1"; else bad "$1" "не ожидалось «$3» в:"$'\n'"$2"; fi; }
expect_eq()    { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "получено «$2», ожидалось «$3»"; fi; }

finish() {
  printf '\n%s: %d пройдено, %d провалено\n' "$(basename "$0" .sh)" "$T_PASS" "$T_FAIL"
  (( T_FAIL == 0 ))
}

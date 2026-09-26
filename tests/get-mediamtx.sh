#!/usr/bin/env bash
# Скачивает MediaMTX той же версии, что ставит setup.sh, в tests/.cache (с проверкой
# контрольной суммы) и печатает путь к программе. Используется интеграционными тестами.
set -euo pipefail
cd "$(dirname "$0")/.."

ver=$(sed -n 's/^MEDIAMTX_VERSION="\${MEDIAMTX_VERSION:-\(v[0-9.]*\)}"$/\1/p' setup.sh)
[[ -n $ver ]] || { echo "Не нашёл MEDIAMTX_VERSION в setup.sh" >&2; exit 1; }

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)        plat=linux_amd64;   ext=tar.gz; bin=mediamtx ;;
  Linux-aarch64)       plat=linux_arm64;   ext=tar.gz; bin=mediamtx ;;
  Darwin-arm64)        plat=darwin_arm64;  ext=tar.gz; bin=mediamtx ;;
  Darwin-x86_64)       plat=darwin_amd64;  ext=tar.gz; bin=mediamtx ;;
  MINGW*|MSYS*|CYGWIN*) plat=windows_amd64; ext=zip;   bin=mediamtx.exe ;;
  *) echo "Неизвестная платформа: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

dir=tests/.cache/mediamtx-$ver
if [[ -x $dir/$bin ]]; then echo "$PWD/$dir/$bin"; exit 0; fi

file=mediamtx_${ver}_${plat}.${ext}
url=https://github.com/bluenviron/mediamtx/releases/download/$ver
mkdir -p "$dir"
echo "Скачиваю MediaMTX $ver ($plat)…" >&2
curl -fsSL --retry 3 -o "$dir/$file" "$url/$file"
curl -fsSL --retry 3 -o "$dir/checksums.sha256" "$url/checksums.sha256"
(cd "$dir" && grep -F " *$file" checksums.sha256 | sha256sum -c --quiet -) \
  || { echo "Контрольная сумма MediaMTX не совпала" >&2; exit 1; }
if [[ $ext == zip ]]; then unzip -o -q "$dir/$file" "$bin" -d "$dir"; else tar -xzf "$dir/$file" -C "$dir" "$bin"; fi
rm -f "$dir/$file"
echo "$PWD/$dir/$bin"

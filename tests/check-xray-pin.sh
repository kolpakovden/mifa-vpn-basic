#!/usr/bin/env bash
# Сверяет закреплённые в install.sh версию и SHA256 Xray с официальным релизом
# XTLS/Xray-core: скачивает архивы amd64 и arm64, вычисляет SHA256 и сравнивает
# с закреплённым значением и с файлом .dgst релиза.
#
#   tests/check-xray-pin.sh OUT_DIR
#
# В GitHub Actions дополнительно проверяется, что релиз не является
# pre-release, и выводится последняя доступная версия.
set -euo pipefail

OUT="${1:?Укажите каталог для архивов}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"
mkdir -p "$OUT"

pin() { sed -n "s/^readonly $1=\"\\([^\"]*\\)\"/\\1/p" "$INSTALL_SH"; }
VERSION="$(pin XRAY_PINNED_VERSION)"
BASE="$(pin XRAY_RELEASE_BASE)"
[[ -n "$VERSION" && -n "$BASE" ]] || { echo "Не удалось прочитать закреплённую версию из install.sh" >&2; exit 1; }
echo "Закреплённая версия: ${VERSION}"

rc=0
for pair in "64:$(pin XRAY_PINNED_SHA256_64)" "arm64-v8a:$(pin XRAY_PINNED_SHA256_ARM64)"; do
  arch="${pair%%:*}"
  pinned="${pair#*:}"
  file="${OUT}/Xray-linux-${arch}.zip"
  url="${BASE}/${VERSION}/Xray-linux-${arch}.zip"
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --max-time 600 -o "$file" "$url"
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --max-time 60 -o "${file}.dgst" "${url}.dgst"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  dgst="$(sed -nE 's/^SHA(2-)?256 *= *([0-9A-Fa-f]{64}).*$/\2/p' "${file}.dgst" | tr 'A-F' 'a-f' | sed -n '1p')"
  printf '%-10s закреплён %s\n%-10s скачан    %s\n%-10s .dgst     %s\n' "$arch" "$pinned" "" "$actual" "" "${dgst:-нет}"
  if [[ "$actual" != "$pinned" ]]; then
    echo "ОШИБКА: SHA256 скачанного Xray-linux-${arch}.zip не совпадает с закреплённым" >&2
    rc=1
  fi
  if [[ "$dgst" != "$pinned" ]]; then
    echo "ОШИБКА: SHA256 в .dgst релиза не совпадает с закреплённым для ${arch}" >&2
    rc=1
  fi
done

if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  pre="$(gh api "repos/XTLS/Xray-core/releases/tags/${VERSION}" --jq '.prerelease')"
  if [[ "$pre" != "false" ]]; then
    echo "ОШИБКА: ${VERSION} помечен как pre-release" >&2
    rc=1
  fi
  latest="$(gh api repos/XTLS/Xray-core/releases/latest --jq '.tag_name')"
  if [[ "$latest" != "$VERSION" ]]; then
    echo "::notice::Доступна более новая версия Xray: ${latest} (закреплена ${VERSION}). Обновление - отдельным PR с новым SHA256."
  fi
fi

if (( rc == 0 )); then
  echo "Закреплённые SHA256 совпадают со скачанными архивами и .dgst релиза ${VERSION}"
fi
exit "$rc"

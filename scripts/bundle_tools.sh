#!/usr/bin/env bash
# Zkopíruje pandoc + poppler (pdftotext, pdfinfo) a jejich dylibs do
# <APP>/Contents/Helpers/ a opraví rpath. Spouští se jako Xcode Run Script phase
# (proměnné CODESIGNING_FOLDER_PATH, EXPANDED_CODE_SIGN_IDENTITY dodá Xcode),
# nebo ručně: ./scripts/bundle_tools.sh /cesta/SpiceHarvester.app "-"
set -euo pipefail

APP="${1:-${CODESIGNING_FOLDER_PATH:?chybí cesta k .app}}"
SIGN_ID="${2:-${EXPANDED_CODE_SIGN_IDENTITY:--}}"
HELPERS="$APP/Contents/Helpers"
LIBS="$HELPERS/lib"
mkdir -p "$HELPERS"

command -v dylibbundler >/dev/null || { echo "chybí dylibbundler (brew install dylibbundler)"; exit 1; }

bundle_one() {
  local name="$1"
  local src; src="$(command -v "$name")" || { echo "nenalezeno: $name"; exit 1; }
  cp -f "$src" "$HELPERS/$name"
  # vlož dylibs do Helpers/lib a přepiš odkazy na @executable_path/lib
  dylibbundler -of -b -x "$HELPERS/$name" -d "$LIBS" -p "@executable_path/lib"
}

for t in pandoc pdftotext pdfinfo; do bundle_one "$t"; done

# podepiš s hardened runtime, aby šly spustit pod sandboxem rodiče.
# Nejdřív dylibs (nemají execute bit, ale i je musí hardened runtime ověřit),
# teprve pak spustitelné nástroje.
if [ -d "$LIBS" ]; then
  find "$LIBS" -type f -name '*.dylib' -exec \
    codesign --force --options runtime --timestamp=none -s "$SIGN_ID" {} \;
fi
find "$HELPERS" -maxdepth 1 -type f -perm -u+x -exec \
  codesign --force --options runtime --timestamp=none -s "$SIGN_ID" {} \;

echo "Hotovo: nástroje v $HELPERS"

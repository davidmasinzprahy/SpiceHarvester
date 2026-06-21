#!/usr/bin/env bash
# Doinstaluje ocrmypdf do bundlovaného Pythonu (Contents/Helpers/python z Fáze 2)
# a zkopíruje ghostscript (gs), tesseract a tessdata (jen 5 jazyků) + dylibs do
# Contents/Helpers/. Spouští se jako Xcode Run Script phase (po bundle_python_tools.sh)
# nebo ručně: ./scripts/bundle_ocr_tools.sh /cesta/SpiceHarvester.app "-"
#
# POZNÁMKA: ghostscript je licencován pod AGPL — uveď to v licenčních podmínkách aplikace.
set -euo pipefail

APP="${1:-${CODESIGNING_FOLDER_PATH:?chybí cesta k .app}}"
SIGN_ID="${2:-${EXPANDED_CODE_SIGN_IDENTITY:--}}"
# Ad-hoc podpis (`-`) nelze opatřit secure timestampem; Developer ID ano a
# notarizace ho vyžaduje. Flag se proto odvodí podle identity automaticky —
# žádná ruční editace před notarizací.
if [ "$SIGN_ID" = "-" ]; then TS="--timestamp=none"; else TS="--timestamp"; fi
HELPERS="$APP/Contents/Helpers"
PYDIR="$HELPERS/python"
LIBS="$HELPERS/lib"
TESSDATA_DST="$HELPERS/tessdata"
LANGS=(ces slk deu pol eng osd)

command -v dylibbundler >/dev/null || { echo "chybí dylibbundler (brew install dylibbundler)"; exit 1; }
[ -x "$PYDIR/bin/python3" ] || { echo "chybí bundlovaný Python — spusť nejdřív bundle_python_tools.sh"; exit 1; }

# 1) ocrmypdf do bundlovaného Pythonu (jen pokud chybí)
if ! "$PYDIR/bin/python3" -c "import ocrmypdf" >/dev/null 2>&1; then
  "$PYDIR/bin/python3" -m pip install --no-warn-script-location ocrmypdf
fi
# wrapper ocrmypdf: PATH ať najde bundlovaný gs/tesseract, TESSDATA_PREFIX ať
# tesseract 5 najde bundlovaná tessdata
cat > "$HELPERS/ocrmypdf" <<'WRAP'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$DIR:$PATH"
export TESSDATA_PREFIX="$DIR/tessdata"
exec "$DIR/python/bin/python3" -m ocrmypdf "$@"
WRAP
chmod +x "$HELPERS/ocrmypdf"

# 2) zkopíruj gs a tesseract binárky + dylibs
bundle_bin() {
  local name="$1"
  local src; src="$(command -v "$name")" || { echo "nenalezeno: $name"; exit 1; }
  cp -f "$src" "$HELPERS/$name"
  dylibbundler -of -b -x "$HELPERS/$name" -d "$LIBS" -p "@executable_path/lib"
}
bundle_bin gs
bundle_bin tesseract

# 3) tessdata jen pro vybrané jazyky
src_tessdata="$(dirname "$(command -v tesseract)")/../share/tessdata"
mkdir -p "$TESSDATA_DST"
for lang in "${LANGS[@]}"; do
  [ -f "$src_tessdata/$lang.traineddata" ] && cp -f "$src_tessdata/$lang.traineddata" "$TESSDATA_DST/"
done

# 4) podepiš dylibs (nemají +x), pak spustitelné a wrappery (hardened runtime)
if [ -d "$LIBS" ]; then
  find "$LIBS" -type f -name '*.dylib' -exec \
    codesign --force --options runtime $TS -s "$SIGN_ID" {} \;
fi
find "$HELPERS" -maxdepth 1 -type f -perm -u+x -exec \
  codesign --force --options runtime $TS -s "$SIGN_ID" {} \;

echo "Hotovo: ocrmypdf + gs + tesseract + tessdata v $HELPERS"

#!/usr/bin/env bash
# Vloží relokovatelný Python + csvkit do <APP>/Contents/Helpers/python a vytvoří
# tenký wrapper Contents/Helpers/in2csv. Spouští se jako Xcode Run Script phase
# nebo ručně: ./scripts/bundle_python_tools.sh /cesta/SpiceHarvester.app "-"
#
# Vyžaduje proměnnou PBS_URL s odkazem na python-build-standalone tarball
# (https://github.com/astral-sh/python-build-standalone/releases) pro cílovou
# architekturu, např. cpython-3.12.*-aarch64-apple-darwin-install_only.tar.gz
set -euo pipefail

APP="${1:-${CODESIGNING_FOLDER_PATH:?chybí cesta k .app}}"
SIGN_ID="${2:-${EXPANDED_CODE_SIGN_IDENTITY:--}}"
PBS_URL="${PBS_URL:?nastav PBS_URL na python-build-standalone tarball}"
HELPERS="$APP/Contents/Helpers"
PYDIR="$HELPERS/python"
mkdir -p "$HELPERS"

# 1) Stáhni a rozbal relokovatelný Python (idempotentně)
if [ ! -x "$PYDIR/bin/python3" ]; then
  tmp="$(mktemp -d)"
  curl -fsSL "$PBS_URL" -o "$tmp/python.tar.gz"
  rm -rf "$PYDIR"
  mkdir -p "$PYDIR"
  # tarball má kořen "python/" -> rozbal a přesuň obsah
  tar -xzf "$tmp/python.tar.gz" -C "$tmp"
  mv "$tmp/python/"* "$PYDIR/"
  rm -rf "$tmp"
fi

# 2) Nainstaluj csvkit do bundlovaného Pythonu
"$PYDIR/bin/python3" -m pip install --upgrade --no-warn-script-location csvkit

# 3) Tenký wrapper: shebang nemůže být @executable_path, proto wrapper přes bash
cat > "$HELPERS/in2csv" <<'WRAP'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/python/bin/python3" -m csvkit.utilities.in2csv "$@"
WRAP
chmod +x "$HELPERS/in2csv"

# 4) Podepiš všechny Mach-O (python binárky, .so moduly) i wrapper
find "$PYDIR" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -exec \
  codesign --force --options runtime --timestamp=none -s "$SIGN_ID" {} \; 2>/dev/null || true
codesign --force --options runtime --timestamp=none -s "$SIGN_ID" "$HELPERS/in2csv"

echo "Hotovo: Python + csvkit v $PYDIR, wrapper $HELPERS/in2csv"

#!/usr/bin/env bash
# Extract Valheim's meshes and textures from this Mac's copy of the game into the
# catalog Munin reads. The app runs this from Munin › Set Up Game Assets…; it also
# works on its own:
#
#   tools/setup_assets.sh [world ...]
#
# Each world adds the trees, rocks and creatures it contains. Python packages go into
# a private environment under Application Support, so nothing else on the Mac changes.
# MUNIN_GAME overrides where the game is, MUNIN_MODS where its BepInEx plugins are,
# MUNIN_CATALOG where the catalog goes.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
support="$HOME/Library/Application Support/Munin"
catalog="${MUNIN_CATALOG:-$support/catalog}"
venv="$support/python"
unitypy="UnityPy==1.25.4" # the version the extractor is tested with

step() { echo "▸ $*"; }
fail() { echo "✗ $*" >&2; exit 1; }

# --- the game ------------------------------------------------------------------

game="${MUNIN_GAME:-$HOME/Library/Application Support/Steam/steamapps/common/Valheim/valheim.app/Contents/Resources/Data}"
[ -d "$game/StreamingAssets/SoftRef/Bundles" ] \
  || fail "Valheim isn't installed where Steam puts it ($game). Install it through Steam on this Mac, then try again."
step "Valheim found"

# Mods: the newest profile of each mod manager, so modded pieces get real shapes too.
mods=()
if [ -n "${MUNIN_MODS:-}" ]; then
  mods+=("$MUNIN_MODS")
else
  for profiles in "$HOME/Library/Application Support/com.r2modmac/profiles" \
                  "$HOME/Library/Application Support/r2modmanPlus-local/Valheim/profiles" \
                  "$HOME/Library/Application Support/Thunderstore Mod Manager/DataFolder/Valheim/profiles"; do
    [ -d "$profiles" ] || continue
    newest="$(ls -td "$profiles"/*/BepInEx/plugins 2>/dev/null | head -1 || true)"
    [ -n "$newest" ] && mods+=("$newest")
  done
fi
for m in ${mods[@]+"${mods[@]}"}; do step "Mods from ${m#"$HOME/"}"; done

# --- Python ----------------------------------------------------------------------

python=""
for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  [ -x "$candidate" ] || continue
  # Apple's /usr/bin/python3 is a stub until the Command Line Tools are installed.
  if [ "$candidate" = /usr/bin/python3 ] && ! xcode-select -p >/dev/null 2>&1; then continue; fi
  if "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null; then python="$candidate"; break; fi
done
if [ -z "$python" ]; then
  xcode-select --install >/dev/null 2>&1 || true
  fail "Python is needed. macOS is now offering to install the Command Line Tools, which include it: click Install, wait for it to finish, then run the setup again."
fi

if ! "$venv/bin/python" -c 'import UnityPy, numpy' >/dev/null 2>&1; then
  step "Installing UnityPy and numpy (one time, about 60 MB)…"
  rm -rf "$venv"
  "$python" -m venv "$venv"
  "$venv/bin/python" -m pip install --quiet --disable-pip-version-check --upgrade pip
  "$venv/bin/python" -m pip install --quiet --disable-pip-version-check "$unitypy" numpy
fi

# --- extract ---------------------------------------------------------------------

args=(--game "$game" --out "$catalog.partial")
for m in ${mods[@]+"${mods[@]}"}; do args+=(--extra "$m"); done
for w in "$@"; do [ -e "$w" ] && args+=(--world "$w"); done
step "Extracting meshes and textures. This takes a few minutes and about 6 GB of memory…"
rm -rf "$catalog.partial"
# Keep the old catalog until the new one is complete.
[ -d "$catalog/_mod_bundles" ] && mkdir -p "$catalog.partial" && cp -R "$catalog/_mod_bundles" "$catalog.partial/"
"$venv/bin/python" -I -u "$here/extract_meshes.py" "${args[@]}"
rm -rf "$catalog"
mv "$catalog.partial" "$catalog"
step "Done"

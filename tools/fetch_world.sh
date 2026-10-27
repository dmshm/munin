#!/usr/bin/env bash
# Download the latest world save from a dedicated server over FTP.
#
#   tools/fetch_world.sh <env-file> [dest-dir]
#
# The env file stays wherever you keep it — never in this repo — and defines
# FTP_HOST, FTP_PORT, FTP_USER, FTP_PASSWORD and WORLD_NAME. SAVE_DIR overrides
# where the server keeps worlds (default: the dedicated server's worlds_local).
#
# Valheim 1.0 servers save a world as a directory of chunks; older ones as a single
# <world>.db. Either way it lands in dest-dir (default: the app's worlds folder),
# ready to open.
set -euo pipefail

env_file="${1:?usage: $0 <env-file> [dest-dir]}"
set -a; . "$env_file"; set +a
: "${FTP_HOST:?} ${FTP_PORT:?} ${FTP_USER:?} ${FTP_PASSWORD:?} ${WORLD_NAME:?}"
save_dir="${SAVE_DIR:-.config/unity3d/IronGate/Valheim/worlds_local}"
dest="${2:-$HOME/Library/Application Support/Munin/worlds}"
base="ftp://$FTP_HOST:$FTP_PORT/$save_dir"

ftp() { curl -sS --fail --max-time 600 --user "$FTP_USER:$FTP_PASSWORD" "$@"; }

# Many hosts refuse NLST, so take names from the long LIST format.
if ftp "$base/$WORLD_NAME/" >/dev/null 2>&1; then
  out="$dest/$WORLD_NAME"
  mkdir -p "$out"
  # The server saves every few minutes and renames chunks as it goes, so a file
  # can vanish between listing and download: start over when that happens.
  for attempt in 1 2 3 4 5; do
    find "$out" -type f -delete # old chunk revisions would otherwise linger
    ok=1
    while read -r name; do
      ftp "$base/$WORLD_NAME/$name" -o "$out/$name" 2>/dev/null || { ok=0; break; }
    done < <(ftp "$base/$WORLD_NAME/" | awk '{print $NF}')
    [ "$ok" = 1 ] && break
    echo "The server saved mid-download; retrying ($attempt)…" >&2
    sleep 5
  done
  [ "$ok" = 1 ] || { echo "Gave up: the save kept changing underneath." >&2; exit 1; }
  echo "Fetched $(ls "$out" | wc -l | tr -d ' ') files into $out"
else
  mkdir -p "$dest"
  ftp "$base/$WORLD_NAME.db" -o "$dest/$WORLD_NAME.db"
  echo "Fetched $dest/$WORLD_NAME.db"
fi

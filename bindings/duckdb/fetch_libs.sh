#!/usr/bin/env bash
# Fetch prebuilt DuckDB *static* libraries for the current host into
# bindings/duckdb/lib/<os>_<arch>/.
#
# The archives come from github.com/duckdb/duckdb-go-bindings — the DuckDB
# org's repo of pre-compiled static libs (built in their CI from the full
# source tree; it's what go-duckdb links by default). Each platform dir holds
# libduckdb_static.a plus the third-party and statically-bundled-extension
# archives; the Odin foreign import block in imports.odin lists them all.
# Static linking means no loader-path (LD_LIBRARY_PATH / DYLD_LIBRARY_PATH)
# dance at run time — binaries are self-contained (+~50MB).
#
# Usage:
#   bash bindings/duckdb/fetch_libs.sh [bindings-tag]
#
# `bindings-tag` defaults to $DUCKDB_BINDINGS_VERSION or the pinned default
# below. Tags are duckdb-go-bindings tags, NOT DuckDB versions — v0.10503.0
# corresponds to DuckDB v1.5.3 (see their README for the mapping). When
# bumping, also refresh input/duckdb.h from the same tag and regenerate the
# Odin bindings (`just gen-duckdb-bindings`) so header and library agree.
#
# Windows is not covered: duckdb-go-bindings ships MinGW-style .a archives
# there, which Odin's MSVC linker can't consume. Windows keeps linking the
# official shared duckdb.lib/duckdb.dll — fetch libduckdb-windows-amd64.zip
# from a DuckDB release into lib/windows_amd64/ manually.
set -euo pipefail

DEFAULT_VERSION="v0.10503.0" # DuckDB v1.5.3
VERSION="${1:-${DUCKDB_BINDINGS_VERSION:-$DEFAULT_VERSION}}"

REPO="duckdb/duckdb-go-bindings"

# Resolve this script's directory so the script works from any CWD.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

uname_s="$(uname -s)"
uname_m="$(uname -m)"

# Map host -> (our lib dir suffix, duckdb-go-bindings platform dir).
case "$uname_s" in
  Linux)
    case "$uname_m" in
      x86_64|amd64) os_arch="linux_amd64"; plat="linux-amd64" ;;
      aarch64|arm64) os_arch="linux_arm64"; plat="linux-arm64" ;;
      *) echo "unsupported linux arch: $uname_m" >&2; exit 1 ;;
    esac
    ;;
  Darwin)
    case "$uname_m" in
      arm64) os_arch="darwin_arm64"; plat="darwin-arm64" ;;
      x86_64) os_arch="darwin_amd64"; plat="darwin-amd64" ;;
      *) echo "unsupported darwin arch: $uname_m" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "unsupported OS: $uname_s (Windows links the shared lib — see the header comment)" >&2
    exit 1
    ;;
esac

dest="$here/lib/$os_arch"
mkdir -p "$dest"

# List the platform's .a files from the repo at the pinned tag. The set is
# tied to DuckDB's bundled-extension list and can change between versions,
# so discover it rather than hardcoding. (If it does change, the foreign
# import list in imports.odin must be updated to match — the Odin compiler
# will point out any missing archive at link time.)
echo "fetch_libs: listing $REPO lib/$plat @ $VERSION ..."
listing="$(curl -sfL "https://api.github.com/repos/$REPO/contents/lib/$plat?ref=$VERSION")"
files="$(printf '%s' "$listing" | grep -oE '"name": *"[^"]+\.a"' | cut -d'"' -f4)"

if [ -z "$files" ]; then
  echo "fetch_libs: no .a files found for lib/$plat @ $VERSION" >&2
  exit 1
fi

for f in $files; do
  echo "fetch_libs: $f"
  curl -sfL --retry 4 --retry-delay 2 \
    "https://raw.githubusercontent.com/$REPO/$VERSION/lib/$plat/$f" -o "$dest/$f"
done

# Remove stale shared libraries from the pre-static era so nothing
# accidentally links or loads them.
rm -f "$dest/libduckdb.so" "$dest/libduckdb.dylib"

count="$(printf '%s\n' $files | wc -l | tr -d ' ')"
echo "fetch_libs: $count static archives -> $dest (statically linked; no loader path needed)"

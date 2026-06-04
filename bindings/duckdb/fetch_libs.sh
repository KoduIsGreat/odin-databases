#!/usr/bin/env bash
# Fetch a prebuilt DuckDB C-API library for the current host into
# bindings/duckdb/lib/<os>_<arch>/. DuckDB ships official prebuilt libraries
# per platform, so there is no C++ toolchain / source build to run here — we
# just download and unpack the right archive.
#
# Usage:
#   bash bindings/duckdb/fetch_libs.sh [version]
#
# `version` defaults to $DUCKDB_VERSION or the pinned default below. Pass a
# tag like v1.1.3 to fetch a specific release.
set -euo pipefail

DEFAULT_VERSION="v1.1.3"
VERSION="${1:-${DUCKDB_VERSION:-$DEFAULT_VERSION}}"

# Resolve this script's directory so the script works from any CWD.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

uname_s="$(uname -s)"
uname_m="$(uname -m)"

# Map host -> (odin os_arch dir, release asset name, shared-lib filename).
case "$uname_s" in
  Linux)
    os="linux"
    case "$uname_m" in
      x86_64|amd64) arch="amd64"; asset="libduckdb-linux-amd64.zip" ;;
      aarch64|arm64) arch="arm64"; asset="libduckdb-linux-aarch64.zip" ;;
      *) echo "unsupported linux arch: $uname_m" >&2; exit 1 ;;
    esac
    libfile="libduckdb.so"
    ;;
  Darwin)
    os="darwin"
    case "$uname_m" in
      arm64) arch="arm64" ;;
      x86_64) arch="amd64" ;;
      *) echo "unsupported darwin arch: $uname_m" >&2; exit 1 ;;
    esac
    # DuckDB ships a single universal macOS binary for both arches.
    asset="libduckdb-osx-universal.zip"
    libfile="libduckdb.dylib"
    ;;
  *)
    echo "unsupported OS: $uname_s (Windows: fetch libduckdb-windows-amd64.zip manually)" >&2
    exit 1
    ;;
esac

dest="$here/lib/${os}_${arch}"
url="https://github.com/duckdb/duckdb/releases/download/${VERSION}/${asset}"

echo "Fetching DuckDB ${VERSION} (${asset}) -> ${dest}/"
mkdir -p "$dest"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fSL --retry 4 --retry-delay 2 -o "$tmp/duckdb.zip" "$url"
unzip -o "$tmp/duckdb.zip" -d "$tmp" >/dev/null

# Copy the shared library and the C header (handy for reference / bindgen).
cp "$tmp/$libfile" "$dest/$libfile"
if [ -f "$tmp/duckdb.h" ]; then
  mkdir -p "$here/include"
  cp "$tmp/duckdb.h" "$here/include/duckdb.h"
fi

echo "Done. Linked at runtime via LD_LIBRARY_PATH/DYLD_LIBRARY_PATH=$dest"
echo "(the 'just' duckdb recipes set this for you)"

#!/usr/bin/env bash
# Builds a static SQLite library for the current host into lib/<os>_<arch>/.
# Run on each target host (macOS arm64, macOS amd64, Linux amd64, Linux arm64).
# For Windows, use build_libs.bat.

set -euo pipefail
cd "$(dirname "$0")"

uname_s=$(uname -s)
uname_m=$(uname -m)

case "$uname_s" in
	Darwin) os=darwin ;;
	Linux)  os=linux  ;;
	*) echo "Unsupported OS: $uname_s"; exit 1 ;;
esac

case "$uname_m" in
	arm64|aarch64) arch=arm64 ;;
	x86_64|amd64)  arch=amd64 ;;
	*) echo "Unsupported arch: $uname_m"; exit 1 ;;
esac

outdir="lib/${os}_${arch}"
mkdir -p "$outdir"

CFLAGS=(
	-O2
	-fPIC
	-DSQLITE_ENABLE_FTS5
	-DSQLITE_ENABLE_JSON1
	-DSQLITE_ENABLE_RTREE
	-DSQLITE_ENABLE_COLUMN_METADATA
	-DSQLITE_THREADSAFE=1
	-DSQLITE_DEFAULT_FOREIGN_KEYS=1
)

echo ">> Compiling sqlite3.c -> $outdir/sqlite3.o"
cc "${CFLAGS[@]}" -c src/sqlite3.c -o "$outdir/sqlite3.o"

echo ">> Archiving -> $outdir/libsqlite3.a"
ar rcs "$outdir/libsqlite3.a" "$outdir/sqlite3.o"
rm "$outdir/sqlite3.o"

echo "Done: $outdir/libsqlite3.a"

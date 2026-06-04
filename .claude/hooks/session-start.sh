#!/bin/bash
# SessionStart hook: provision the toolchain odin-databases needs so that
# `just check-all`, `just test`, and `just run` work in Claude Code on the web.
#
# Installs (idempotently):
#   - the Odin compiler, pinned to the same release CI uses (dev-2026-04)
#   - just (recipe runner) and the sqlite3 CLI (used by DB-mode codegen)
#   - a static libsqlite3.a for this host (so the SQLite driver links)
#
# Web-only: it no-ops outside the remote environment so local setups are
# left untouched.
set -euo pipefail

# Only run in Claude Code on the web (remote) environment.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Pin the Odin release the code is built against (keep in sync with
# .github/workflows/ci.yml).
ODIN_VERSION="dev-2026-04"
ODIN_DIR="/opt/odin"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

# --- Odin compiler -----------------------------------------------------------
if ! command -v odin >/dev/null 2>&1; then
  echo ">> Installing Odin ${ODIN_VERSION}"
  url="https://github.com/odin-lang/Odin/releases/download/${ODIN_VERSION}/odin-linux-amd64-${ODIN_VERSION}.tar.gz"
  tmp="$(mktemp -d)"
  for i in 1 2 3 4; do
    if curl -fsSL -m 300 -o "$tmp/odin.tar.gz" "$url"; then break; fi
    echo "   download attempt $i failed, retrying..."; sleep $((2 ** i))
  done
  mkdir -p "$tmp/extract"
  tar -xzf "$tmp/odin.tar.gz" -C "$tmp/extract"
  rm -rf "$ODIN_DIR"
  # The tarball expands to a versioned dir (odin-linux-amd64-nightly+DATE).
  mv "$tmp/extract"/odin-linux-amd64-* "$ODIN_DIR"
  ln -sf "$ODIN_DIR/odin" /usr/local/bin/odin
  rm -rf "$tmp"
fi

# --- apt packages: just + sqlite3 CLI ----------------------------------------
need_apt=()
command -v just    >/dev/null 2>&1 || need_apt+=(just)
command -v sqlite3 >/dev/null 2>&1 || need_apt+=(sqlite3)
if [ "${#need_apt[@]}" -gt 0 ]; then
  echo ">> Installing apt packages: ${need_apt[*]}"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need_apt[@]}"
fi

# build_libs.sh invokes `cc`; ensure it resolves (fall back to clang).
command -v cc >/dev/null 2>&1 || ln -sf "$(command -v clang)" /usr/local/bin/cc

# --- SQLite static lib for this host -----------------------------------------
# Only darwin_arm64 ships in the repo; build linux_amd64 so the SQLite driver
# (and the root demo / sqlite tests) link.
lib="$PROJECT_DIR/bindings/sqlite/lib/linux_amd64/libsqlite3.a"
if [ ! -f "$lib" ]; then
  echo ">> Building SQLite static lib"
  bash "$PROJECT_DIR/bindings/sqlite/build_libs.sh"
fi

# --- DuckDB shared lib for this host -----------------------------------------
# The DuckDB driver links a prebuilt shared library (not checked in, ~50MB);
# fetch it so `just check-all`, `just test`, and the duckdb examples link.
duck_lib="$PROJECT_DIR/bindings/duckdb/lib/linux_amd64/libduckdb.so"
if [ ! -f "$duck_lib" ]; then
  echo ">> Fetching DuckDB shared lib"
  bash "$PROJECT_DIR/bindings/duckdb/fetch_libs.sh" || \
    echo "   (DuckDB fetch failed — the duckdb driver suite will not link until 'just duckdb-lib' succeeds)"
fi

echo ">> Toolchain ready: $(odin version 2>/dev/null) | $(just --version 2>/dev/null) | $(sqlite3 --version 2>/dev/null | cut -d' ' -f1) sqlite3"

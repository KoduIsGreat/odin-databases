#!/usr/bin/env bash
#
# Regenerate the DuckDB Odin bindings from input/duckdb.h via odin-c-bindgen.
# Use `just gen-duckdb-bindings`, which calls this script.
#
# Why this wrapper exists (don't call `bindgen.bin bindings/duckdb` directly):
#
#   duckdb.h does `#include <stdint.h> / <stdbool.h> / <stddef.h>`. bindgen
#   parses it with libclang, and libclang does NOT locate the C standard and
#   compiler-builtin headers on its own — on macOS especially, there is no
#   /usr/include at all without an SDK, and the builtin headers (stdbool.h,
#   stddef.h) live in the libclang resource dir, not the SDK.
#
#   When those headers aren't found, libclang does not hard-fail the run: it
#   silently falls back to `int` for every unresolved type. The result is
#   BROKEN bindings — idx_t (uint64_t) -> i32, every int64_t/int8_t -> i32,
#   bool -> Bool — that then fail to compile against drivers/duckdb. This is
#   the "I pulled the branch and it doesn't work" trap: a stale regenerate
#   left bad types in the working tree.
#
#   So we hand clang two include dirs explicitly:
#     1. <libclang resource dir>/include  — stdbool.h, stddef.h, builtins
#     2. <SDK>/usr/include                — stdint.h and the system headers
#
#   These paths are host-specific, so we inject them at generation time into a
#   gitignored config copy (.bindgen.gen.sjson) rather than committing them
#   into bindgen.sjson. The committed bindgen.sjson stays portable.
#
# Overrides:
#   LLVM_PREFIX  libclang/clang install prefix
#                (default: `brew --prefix llvm`, else /opt/homebrew/opt/llvm)
#   SDKROOT      platform SDK path (default: `xcrun --show-sdk-path`)
#
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

includes=()

case "$(uname -s)" in
Darwin)
	# Builtin headers (stdbool.h, stddef.h) live in the libclang resource dir.
	# Match the clang that owns the libclang bindgen links (Homebrew LLVM).
	llvm_prefix="${LLVM_PREFIX:-$(brew --prefix llvm 2>/dev/null || echo /opt/homebrew/opt/llvm)}"
	res_dir=""
	if [ -x "$llvm_prefix/bin/clang" ]; then
		res_dir="$("$llvm_prefix/bin/clang" -print-resource-dir)"
	elif command -v clang >/dev/null 2>&1; then
		res_dir="$(clang -print-resource-dir)"
	fi
	[ -n "$res_dir" ] && includes+=("$res_dir/include")

	# System headers (stdint.h) live in the SDK.
	sdk="${SDKROOT:-$(xcrun --show-sdk-path 2>/dev/null || true)}"
	[ -n "$sdk" ] && includes+=("$sdk/usr/include")
	;;
esac

if [ "${#includes[@]}" -eq 0 ]; then
	# Linux / other: libclang typically finds /usr/include and its own
	# builtins, so the committed config works as-is.
	exec bindgen.bin "$here"
fi

# Append the host include paths to a generated config copy and run that.
# (bindgen treats the directory of the .sjson file as the working dir, so
# inputs/output_folder still resolve relative to bindings/duckdb.)
gen_cfg="$here/.bindgen.gen.sjson"
trap 'rm -f "$gen_cfg"' EXIT

{
	cat "$here/bindgen.sjson"
	printf '\n// Auto-injected by gen_bindings.sh — host include paths. Do not commit.\n'
	printf 'clang_include_paths = [\n'
	for inc in "${includes[@]}"; do
		printf '\t"%s",\n' "$inc"
	done
	printf ']\n'
} >"$gen_cfg"

echo "gen-duckdb-bindings: clang include paths:"
for inc in "${includes[@]}"; do echo "  -I $inc"; done

bindgen.bin "$gen_cfg"

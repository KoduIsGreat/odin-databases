# duckdb — Odin bindings for the DuckDB C API

Odin bindings to the [DuckDB](https://duckdb.org) C API, generated from
`duckdb.h` with [`odin-c-bindgen`](https://github.com/karl-zylinski/odin-c-bindgen)
(the same tool, config style, and workflow as the SQLite bindings). The whole C
API surface is generated; the `database:drivers/duckdb` driver uses a small slice
of it (connection lifecycle, eager queries, prepared statements, per-cell value
access).

## Layout

```
bindings/duckdb/
  bindgen.sjson         obg config
  imports.odin          cross-platform foreign import block (appended into the generated pkg)
  input/duckdb.h        the upstream C header fed into obg (pinned; source of truth)
  duckdb/duckdb.odin    GENERATED — Odin bindings (package duckdb_c)
  lib/<os>_<arch>/      prebuilt static archives (NOT checked in — see below)
  fetch_libs.sh         download the prebuilt archives for the current host
  example/main.odin     minimal smoke test
```

The generated package is named `duckdb_c` (not `duckdb`) so it can be imported
alongside the `database:drivers/duckdb` driver package without a name collision.
Types are emitted in `Ada_Case` (`Database`, `Result`, `Timestamp`); functions
and enum members keep their familiar DuckDB spellings (`open`, `value_int64`,
`.TIMESTAMP`). This differs from the SQLite bindings' snake_case choice — see the
comments in `bindgen.sjson` for why.

## (Re)generating bindings

**The generated `duckdb/duckdb.odin` is committed** — a fresh clone builds
without regenerating. You only need to regenerate when you bump
`input/duckdb.h`. Setting up the driver does **not** require this step.

From the repo root:

```sh
just gen-duckdb-bindings        # wraps bindgen.bin via gen_bindings.sh
```

`bindgen.bin` (aka `obg`, the `odin-c-bindgen` binary) reads `input/duckdb.h`,
writes the package into `duckdb/`, and appends `imports.odin` so the foreign
import block ships inside the generated package.

> **Do not run `bindgen.bin bindings/duckdb` directly.** `duckdb.h` includes
> `<stdint.h>`/`<stdbool.h>`/`<stddef.h>`, and bindgen's libclang does not find
> the C standard / compiler-builtin headers on its own (on macOS there is no
> `/usr/include` without an SDK). When it can't resolve them it does **not**
> fail — it silently falls back to `int` for every unknown type, so `idx_t`
> (`uint64_t`) and all the `int64_t`/`int8_t`/`bool` fields collapse to `i32`,
> producing bindings that compile-fail against `drivers/duckdb`. The
> `gen_bindings.sh` wrapper (run by the recipe) feeds clang the right include
> dirs — the libclang resource dir's `include/` plus the platform SDK's
> `usr/include` — and injects them into a gitignored config copy so the
> committed `bindgen.sjson` stays portable. Override `LLVM_PREFIX` / `SDKROOT`
> if your toolchain lives elsewhere. If a regenerate ever leaves an all-`i32`
> diff in `duckdb/duckdb.odin`, those include dirs weren't found —
> `git checkout` the file and fix the paths before retrying.

## Getting the library

Unlike the SQLite bindings (which build a small static lib from source), DuckDB
is a large C++ build, so we **download** pre-compiled archives rather than
build, and we **do not check them into git** (~100MB):

```sh
bash bindings/duckdb/fetch_libs.sh        # or: just duckdb-lib
```

The archives come from
[`duckdb-go-bindings`](https://github.com/duckdb/duckdb-go-bindings) — the
DuckDB org's repo of pre-compiled static libraries (built in their CI from the
full source tree; the same set go-duckdb links by default). Each platform dir
gets `libduckdb_static.a` plus the third-party and statically-bundled-extension
archives (parquet, json, icu, core_functions, …), all listed in the foreign
import block in `imports.odin` alongside the C++ runtime (`system:c++` on
macOS; `system:stdc++` + `system:m` + `system:dl` on Linux).

Pin a different `duckdb-go-bindings` tag with `just duckdb-lib v0.10503.0`,
`DUCKDB_BINDINGS_VERSION=...`, or by editing the default in `fetch_libs.sh` —
tags map to DuckDB versions (v0.10503.0 = DuckDB v1.5.3; see their README).

**Windows** keeps linking the official **shared** `duckdb.lib`/`duckdb.dll`:
the upstream static archives are MinGW-format, which Odin's MSVC linker can't
consume. Unzip `libduckdb-windows-amd64.zip` from a
[DuckDB release](https://github.com/duckdb/duckdb/releases) into
`lib/windows_amd64/` and ship `duckdb.dll` next to your binary.

## Runtime linking

macOS and Linux binaries are statically linked and self-contained — nothing to
set at run time. `odin check` does not link, so type-checking works without
the archives present.

## Using

```odin
import ddb "database:bindings/duckdb/duckdb"

db: ddb.Database
ddb.open(":memory:", &db)
defer ddb.close(&db)

con: ddb.Connection
ddb.connect(db, &con)
defer ddb.disconnect(&con)
```

See `example/main.odin` for a full smoke test:

```sh
just duckdb-bindings-example
```

Most users want the higher-level driver instead — see
[`drivers/duckdb`](../../drivers/duckdb).

## Updating DuckDB

1. Pick a new [`duckdb-go-bindings` tag](https://github.com/duckdb/duckdb-go-bindings/tags)
   and bump the pinned default in `fetch_libs.sh`.
2. Replace `input/duckdb.h` with the `duckdb.h` from the same tag (it sits next
   to the archives, e.g. `lib/darwin-arm64/duckdb.h`) so header and library
   can't drift.
3. Re-run `just gen-duckdb-bindings`.
4. Re-fetch the matching archives with `just duckdb-lib`.

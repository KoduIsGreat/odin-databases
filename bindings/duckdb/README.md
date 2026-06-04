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
  lib/<os>_<arch>/      prebuilt shared library (NOT checked in — see below)
  fetch_libs.sh         download the prebuilt library for the current host
  example/main.odin     minimal smoke test
```

The generated package is named `duckdb_c` (not `duckdb`) so it can be imported
alongside the `database:drivers/duckdb` driver package without a name collision.
Types are emitted in `Ada_Case` (`Database`, `Result`, `Timestamp`); functions
and enum members keep their familiar DuckDB spellings (`open`, `value_int64`,
`.TIMESTAMP`). This differs from the SQLite bindings' snake_case choice — see the
comments in `bindgen.sjson` for why.

## (Re)generating bindings

From the repo root:

```sh
just gen-duckdb-bindings        # or: bindgen.bin bindings/duckdb   (obg)
```

`bindgen.bin` (aka `obg`, the `odin-c-bindgen` binary) reads `input/duckdb.h`,
writes the package into `duckdb/`, and appends `imports.odin` so the foreign
import block ships inside the generated package.

## Getting the library

Unlike the SQLite bindings (which build a small static lib from source), DuckDB
ships large official prebuilt libraries per platform, so we **download** rather
than build, and we **do not check the library into git** (~50MB):

```sh
bash bindings/duckdb/fetch_libs.sh        # or: just duckdb-lib
```

This drops the shared library into `lib/<os>_<arch>/`:

| Host                  | Asset                          | File              |
| --------------------- | ------------------------------ | ----------------- |
| Linux amd64           | `libduckdb-linux-amd64.zip`    | `libduckdb.so`    |
| Linux arm64           | `libduckdb-linux-aarch64.zip`  | `libduckdb.so`    |
| macOS (arm64 / amd64) | `libduckdb-osx-universal.zip`  | `libduckdb.dylib` |
| Windows amd64         | `libduckdb-windows-amd64.zip`  | `duckdb.lib`      |

Pin a different release with `just duckdb-lib v1.1.3`, `DUCKDB_VERSION=v1.1.3`,
or by editing the default in `fetch_libs.sh`. (Windows is mapped in `imports.odin`
but not automated by the script — unzip the asset into `lib/windows_amd64/`.)

## Runtime linking

The bindings link the **shared** library, so the dynamic loader must find it at
run time. The `just` duckdb recipes set `LD_LIBRARY_PATH` (Linux) /
`DYLD_LIBRARY_PATH` (macOS) to the lib dir for you; if you run a binary by hand,
set it yourself:

```sh
LD_LIBRARY_PATH=bindings/duckdb/lib/linux_amd64 ./your-binary
```

`odin check` does not link, so type-checking works without the library present.

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

1. Download a new C API zip from the
   [DuckDB releases](https://github.com/duckdb/duckdb/releases) (it contains
   `duckdb.h`).
2. Replace `input/duckdb.h`, and bump the pinned version in `fetch_libs.sh`.
3. Re-run `just gen-duckdb-bindings`.
4. Re-fetch the matching shared library with `just duckdb-lib`.

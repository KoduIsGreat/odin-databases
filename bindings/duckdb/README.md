# duckdb — Odin bindings for the DuckDB C API

Minimal, hand-written Odin bindings to the stable
[DuckDB](https://duckdb.org) C API (`duckdb.h`). They cover exactly what the
`database:drivers/duckdb` driver needs — connection lifecycle, eager queries,
prepared statements, and per-cell value access — and intentionally omit the
data-chunk/vector streaming API, appenders, extraction, and the type-system
helpers. Grow the binding as the driver grows.

## Layout

```
bindings/duckdb/
  duckdb/duckdb.odin   the bindings (package duckdb_c)
  include/duckdb.h     the upstream C header, for reference / regeneration
  lib/<os>_<arch>/     prebuilt shared library (NOT checked in — see below)
  fetch_libs.sh        download the prebuilt library for the current host
  example/main.odin    minimal smoke test
```

The package is named `duckdb_c` (not `duckdb`) so it can be imported alongside
the `database:drivers/duckdb` driver package without a name collision.

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
or by editing the default in `fetch_libs.sh`. (Windows is mapped in the binding
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

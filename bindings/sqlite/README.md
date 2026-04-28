# sqlite — Odin bindings for SQLite

Static, cross-platform Odin bindings for [SQLite](https://www.sqlite.org/),
generated from the official SQLite amalgamation header using
[`odin-c-bindgen`](https://github.com/karl-zylinski/odin-c-bindgen).

## Layout

```
bindings/sqlite/
  bindgen.sjson         obg config
  imports.odin          cross-platform foreign import block (lives in generated pkg)
  input/sqlite3.h       header fed into obg
  input/sqlite3_footer.odin   hand-written additions appended to generated file
  src/                  sqlite3.c + sqlite3ext.h (used to build static libs)
  sqlite/sqlite3.odin   GENERATED — Odin bindings
  lib/<os>_<arch>/      prebuilt static libs (libsqlite3.a / sqlite3.lib)
  build_libs.sh         build static lib for current Unix host
  build_libs.bat        build static lib for Windows amd64 (run from VS x64 prompt)
  example/main.odin     minimal smoke test
```

## (Re)generating bindings

From the repo root:

```sh
obg bindings/sqlite
```

`obg` is the alias for `bindgen.bin` (`odin-c-bindgen`). It scans
`bindings/sqlite/input/`, writes the package into `bindings/sqlite/sqlite/`,
and appends `imports.odin` and `input/sqlite3_footer.odin` so the foreign
import block and hand-written additions ship inside the generated package.

## Building the static library

Per host:

| Host                  | Command                                          |
| --------------------- | ------------------------------------------------ |
| macOS (arm64 / amd64) | `./build_libs.sh`                                |
| Linux (amd64 / arm64) | `./build_libs.sh`                                |
| Windows amd64         | `build_libs.bat` from a VS x64 native cmd prompt |

Output goes to `lib/<os>_<arch>/`. Commit the libs you build so end users
don't need a C toolchain.

Compile flags enabled by default: FTS5, JSON1, RTREE, column metadata,
thread-safe, foreign keys ON by default.

## Using

```odin
import sql "odin-databases/bindings/sqlite/sqlite"

db: ^sql.sqlite3
if rc := sql.open("test.db", &db); rc != sql.OK {
    // ...
}
defer sql.close(db)
```

See `example/main.odin` for a full smoke test. Run it with:

```sh
cd bindings/sqlite/example && odin run .
```

## Updating SQLite

1. Download a new amalgamation zip from <https://www.sqlite.org/download.html>.
2. Replace `input/sqlite3.h`, `src/sqlite3.c`, `src/sqlite3ext.h`.
3. Re-run `obg bindings/sqlite` from the repo root.
4. Rebuild static libs on each host.

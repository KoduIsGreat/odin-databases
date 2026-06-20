# odin-databases

[![CI](https://github.com/KoduIsGreat/odin-databases/actions/workflows/ci.yml/badge.svg)](https://github.com/KoduIsGreat/odin-databases/actions/workflows/ci.yml)

A database access toolkit for [Odin](https://odin-lang.org):

- **`database:sql`** — a driver-agnostic core (`DB`, `Conn`, `Rows`, `Row`,
  `Stmt`, `Tx`) with a connection pool, transactions, prepared statements,
  reflective/positional row scanning, and errors that carry the offending
  query and call site.
- **`database:sqlbuilder`** — a typed SQL builder where column references and
  predicate values are checked at **compile time**, plus a raw string escape
  hatch.
- **code generators** — `scangen` (fast row scanners), `schemagen` (typed
  column descriptors + row structs) driven by struct annotations *or* live
  database introspection, and `querygen` (typed data-access procs from annotated
  `.sql` queries, with result types inferred from the database).
- **drivers** — a SQLite driver (JSON1/FTS5/R*Tree, loadable extensions), a
  pure-Odin **PostgreSQL** driver (wire protocol, no libpq; SCRAM-SHA-256, with
  opt-in TLS), a **preliminary DuckDB** driver (over DuckDB's C API), and an
  expectation-based **mock** driver for tests.

See [`DESIGN.md`](DESIGN.md) for the rationale behind each piece and
[`examples/`](examples) for runnable, focused examples.

## Requirements

- The Odin compiler (recent `dev-*` build).
- For the SQLite driver: a static `libsqlite3` for your platform under
  `bindings/sqlite/lib/<os>_<arch>/`. A `darwin_arm64` lib is checked in; build
  others with:

  ```sh
  bash bindings/sqlite/build_libs.sh      # or: just sqlite-lib
  ```

`sqlite3` (the CLI) is only needed to materialize a database for schemagen's
introspection mode or querygen's describe step.

- For the DuckDB driver: the prebuilt DuckDB **static** archives for your
  platform under `bindings/duckdb/lib/<os>_<arch>/`. They are not checked in
  (~100MB); fetch them with:

  ```sh
  bash bindings/duckdb/fetch_libs.sh      # or: just duckdb-lib
  ```

  The archives come from
  [`duckdb-go-bindings`](https://github.com/duckdb/duckdb-go-bindings) (the
  DuckDB org's pre-compiled static libs, the same set go-duckdb links). DuckDB
  is linked **statically** on macOS and Linux, so binaries are self-contained —
  no loader path at run time — at the cost of ~50MB of binary size. Windows
  still links the shared `duckdb.lib`/`duckdb.dll` (the upstream static
  archives are MinGW-format, which MSVC can't consume). See
  [`drivers/duckdb`](drivers/duckdb) for the driver's scope and caveats.

  The Odin bindings are pre-generated and committed, so setup is just "fetch the
  library" — you do **not** need to run `just gen-duckdb-bindings`. Only
  regenerate when bumping the pinned `duckdb.h`, and use that recipe (not
  `bindgen.bin` directly); see
  [`bindings/duckdb/README.md`](bindings/duckdb/README.md) for why.

## Installing it in your project

This repo is an Odin **collection** named `database`. Vendor it (git submodule
or a copy), then pass the collection flag and import with rooted paths:

```sh
git submodule add https://github.com/KoduIsGreat/odin-databases.git vendor/odin-databases
```

```odin
import sql    "database:sql"
import sqlite "database:drivers/sqlite"
import sb     "database:sqlbuilder"
```

```sh
odin build . -collection:database=vendor/odin-databases
```

For editor/LSP resolution, add the collection to your `ols.json`:

```json
{ "collections": [ { "name": "database", "path": "vendor/odin-databases" } ] }
```

## Quick start

```odin
package myapp

import "core:fmt"

import sql    "database:sql"
import sqlite "database:drivers/sqlite"

User :: struct {
	id:   i64,
	name: string,
	age:  int,
}

main :: proc() {
	db, err := sql.open(&sqlite.driver, "app.db") // or ":memory:"
	if err != nil {
        fmt.eprintfln("open: %v", err)
        return
    }
	defer sql.close(db)

	sql.exec(db, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
	sql.exec(db, "INSERT INTO users (name, age) VALUES (?, ?)", "Alice", i64(30))

	rows, qerr := sql.query(db, "SELECT id, name, age FROM users WHERE age >= ?", i64(18))
	if qerr != nil {
        fmt.eprintfln("query: %v", qerr)
        return
    }
	defer sql.rows_close(&rows)

	for sql.next(&rows) {
		u: User
		sql.scan_struct(&rows, &u) // reflective: matches columns to fields by name
		fmt.printfln("%v is %v", u.name, u.age)
	}
	// next() returns false for BOTH a clean end-of-rows and a mid-stream
	// failure, so check rows_err afterward (like Go's rows.Err) — otherwise a
	// truncated result looks complete.
	if rerr := sql.rows_err(&rows); rerr != nil {
        fmt.eprintfln("rows: %v", rerr)
        return
    }
}
```

`sql.scan(&rows, &name, &age)` scans positionally; struct mapping is explicit
(`sql.scan_struct` / `sql.row_scan_struct`, or a scangen-generated concrete
scanner — see codegen below). Passing a lone struct pointer to `sql.scan` is a
**compile-time error** that names the type and the alternatives, not a runtime
mismatch. `sql.query_row(db, ...)` is a single-row convenience. Transactions
(`sql.begin`/`commit`/`rollback`) and prepared statements (`sql.prepare` +
`sql.stmt_exec`) are in the [`quickstart`](examples/quickstart) example.

## Error handling

`sql.Error` is a union of plain Odin values (`Driver_Error | Pool_Error |
Arg_Error | Scan_Error`) — switch on the variant for programmatic handling.
Every error returned by the sql layer is annotated with the SQL text that
caused it and the application call site that issued it (captured via
`#caller_location`, zero effort at the call site), so a failure deep in a call
stack still names its query:

```odin
if _, err := sql.exec(db, "UPDATE users SET nmae = ? WHERE id = ?", name, id); err != nil {
	fmt.println(sql.err_to_string(err))
	// sql driver error code 1: Binder Error: column "nmae" does not exist
	//   query: UPDATE users SET nmae = ? WHERE id = ?
	//   at:    src/store/users.odin(42:15) in update_user
}
```

The context follows deferred failures too: a prepared statement that fails at
`stmt_exec`, a mid-stream `rows_err`, or a `scan` mismatch all report the
originating query. `sql.error_query(err)` / `sql.error_ctx(err)` read the
attached context without a switch. The query string is borrowed, not cloned —
free for the string literals that queries almost always are. See
[`err_handling`](examples/err_handling).

## Typed query builder

Build queries against generated descriptors so a mistyped column or wrong-typed
value is a compile error:

```odin
b: sb.Builder
sb.init(&b); defer sb.destroy(&b)

sb.select(&b, Users.id, Users.name)        // unknown column → won't compile
sb.from(&b, Users)
sb.where_(&b, sb.ge(Users.age, 18))         // ge(Users.age, "x") → won't compile
sb.order_by(&b, sb.desc(Users.age))

q, args := sb.to_query(&b)
rows, _ := sql.query(db, q, ..args)
```

`Users` here is a descriptor generated by **schemagen**. The builder also covers
typed joins (`sb.join` + `sb.col_eq`), inserts (`sb.insert_into` + `sb.bind`),
`update`/`set`, `delete_from`, and CTEs (`sb.with`, incl. `WITH RECURSIVE`);
`raw_*` procs are the escape hatch for SQL it can't yet express. See
[`query_builder`](examples/query_builder).

## Code generation

Three generators turn a schema into Odin code. `schemagen` and `scangen`
compose — run schemagen then scangen; `querygen` is a separate query-first path.

```odin
//+sql:scan          // scangen → a fast scan_User proc
//+sql:table users    // schemagen → the `Users` column descriptors
User :: struct {
	id:   i64,
	name: string,
	age:  int,
}
```

```sh
just gen          # scangen + schemagen on the repo root (or `just gen <dir>`)
```

- **scangen** emits `scan.gen.odin` with concrete `scan_<T>` / `scan_<T>_row`
  procs and a `scan` overload set covering them plus positional scanning.
  Scanning an *unannotated* struct through the set is a compile-time error —
  annotate it, or opt into reflection explicitly via `sql.scan_struct`.
- **schemagen** emits `schema.gen.odin` with typed `Column(T)` descriptors. Its
  **DB mode** introspects a live database instead of structs, emitting the row
  structs too — nullable columns become `Maybe(T)`:

  ```sh
  just schema-db app.db ./myapp     # or `just gen-introspection` for the example
  ```

  DB mode introspects SQLite by default; pass a live PostgreSQL server with
  `-driver=postgres` (introspected via `information_schema`):

  ```sh
  just schema-db-postgres 'postgres://user:pass@localhost:5432/mydb?sslmode=disable' ./myapp
  ```

  A DuckDB database can be introspected with `-driver=duckdb`. It links
  DuckDB (statically, ~50MB), so it's opt-in at build time
  (`-define:SCHEMAGEN_DUCKDB=true`) to keep the default `schemagen`/`odb` free
  of that dependency — the `just` recipe sets the flag for you. Composite
  columns (LIST/STRUCT/MAP/…) have no single-field mapping and are skipped
  with a warning:

  ```sh
  just duckdb-lib                          # once, to fetch libduckdb
  just schema-db-duckdb app.duckdb ./myapp
  ```

See [`introspection`](examples/introspection) for the DB-mode workflow.

- **querygen** is the query-first path (sqlc-style): write annotated `.sql`
  queries, and it emits a typed proc + result struct per query into
  `queries.gen.odin`. Result column types are *inferred* — querygen runs each
  query against a schema-loaded database and reads the result column types from
  the driver (no SQL parser); `?`/`$N` parameters are named and typed by
  `-- arg:` lines:

  ```sql
  -- name: GetUser :one
  -- arg: id i64
  SELECT id, name, age FROM users WHERE id = ?;
  ```

  ```sh
  odb query -db=app.db ./sql ./myapp        # -driver=postgres|duckdb for those
  ```

  ```odin
  user, err := GetUser(db, 1)               // (GetUserRow, sql.Error)
  ```

  Cardinality is `:one` / `:many` / `:exec`. Works across SQLite, PostgreSQL, and
  DuckDB (the latter opt-in at build time, like schemagen). See
  [`queries`](examples/queries).

The `*.gen.odin` files are committed so the demo and examples build on a fresh
clone without a codegen step; CI regenerates them and fails if they drift from
the source.

## Schema migrations

`database:migrate` is a small, driver-agnostic migration runner over the `sql`
core. It applies an ordered set of migrations, records applied versions in a
`schema_migrations` table, and supports rollback. Each migration body and its
bookkeeping row run in one transaction.

```odin
import migrate "database:migrate"

ms, _ := migrate.from_dir("migrations")   // <version>_<name>.up.sql / .down.sql
defer migrate.destroy_migrations(ms)

applied, err := migrate.up(db, ms)         // apply all pending (idempotent)
// migrate.down(db, ms)                    // roll back the most recent one
// migrate.to(db, ms, version)             // up or down to an exact version
// migrate.status(db, ms)                  // per-migration applied/pending
```

Migrations are loaded from `.sql` files named `<version>_<name>.up.sql` (plus an
optional `.down.sql`), where `<version>` is a 14-digit `YYYYMMDDHHMMSS`
timestamp. You can also build the `[]migrate.Migration` slice by hand — the
runner only needs the SQL strings.

**Scaffold a new migration.** `migranew` writes an empty, correctly-named
`<version>_<name>.up.sql` / `.down.sql` pair (fresh timestamp) into a directory:

```sh
just migrate-new migrations "create users"   # or: just odb migrate-new migrations "create users"
# → migrations/20260102030405_create_users.up.sql (+ .down.sql)
```

**Embed instead of reading at runtime.** `migragen` bakes a directory of `.sql`
files into a generated `migrations.gen.odin` (an embedded `[]migrate.Migration`),
so the binary ships its migrations internally — no files to deploy:

```sh
just gen-migrations migrations ./myapp   # writes ./myapp/migrations.gen.odin
```

```odin
migrate.up(db, MIGRATIONS)   // MIGRATIONS is the generated slice
```

**Concurrency.** When the driver supports it (PostgreSQL, via
`pg_advisory_lock`), `up`/`down`/`to` take a session advisory lock for the run,
so several app instances booting at once serialize their migrations instead of
racing. SQLite is single-writer, so it needs no lock. See
[`migrations`](examples/migrations).

## Testing with the mock driver

Test database code without a real database. Pass the test's `t` to `open` and
`close` auto-asserts every expectation was used exactly once:

```odin
import mock "database:drivers/mock"

@(test)
test_active_users :: proc(t: ^testing.T) {
	m, db := mock.open(t)
	defer mock.close(m, db)

	// type-safe fixtures from row structs (no column-name strings, no Value wrapping)
	mock.returns_structs(mock.expect_query(m, "SELECT"), []User{
		{id = 1, name = "Alice", age = 30},
	})

	users, err := find_users_over(db, 18) // your code under test
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(users), 1)
}
```

See [`testing`](examples/testing).

## Development

```sh
just            # list recipes
just run        # regenerate codegen, then run the root demo
just check-all  # type-check every package
just test       # run all test suites
just gen-all    # regenerate every committed *.gen.odin file
```

All recipes pass `-collection:database=.` for you.

The code generators are also exposed through a single **`odb`** CLI (built on
`core:flags`), so each generator is a subcommand with its own `-h`:

```sh
just odb scan ./pkg                       # scangen
just odb schema -db=app.db ./pkg          # schemagen (-driver=postgres for a DSN)
just odb query -db=app.db ./sql ./pkg     # querygen (-driver=postgres|duckdb too)
just odb migrate-new ./migrations "name"  # migranew (scaffold a new migration)
just odb migrate-gen ./migrations ./pkg   # migragen
just odb schema -h                        # flags for a subcommand
just odb-build                            # build a standalone bin/odb
just install                              # build + install odb to ~/.local/bin (on PATH)
```

`just install [dir]` puts a release `odb` on your PATH (default `~/.local/bin`,
or `$ODB_INSTALL_DIR`); `just uninstall [dir]` removes it.

(The individual `tools/<name>` binaries still build and run on their own.)

## Layout

| Import | Path | What |
|---|---|---|
| `database:sql` | `sql/` | core API + connection pool |
| `database:driver` | `driver/` | driver contract (`Driver` vtable, `Value`, `Error`) |
| `database:sqlbuilder` | `sqlbuilder/` | typed SQL builder |
| `database:migrate` | `migrate/` | schema-migration runner (`up`/`down`/`to`/`status`) |
| `database:exec` | `exec/` | async execution layer — runs blocking `sql` work on worker threads with pinned connections, lanes, bounded background jobs, cancellation, and graceful shutdown (for non-blocking servers) |
| `database:exec/nbio` | `exec/nbio/` | bridges `exec` to a `core:nbio` event loop — delivers completions onto the loop thread with per-request deadlines/cancellation ([HTTP.md](exec/nbio/HTTP.md)) |
| `database:drivers/sqlite` | `drivers/sqlite/` | SQLite driver |
| `database:drivers/postgres` | `drivers/postgres/` | pure-Odin PostgreSQL driver ([README](drivers/postgres/README.md)) |
| `database:drivers/duckdb` | `drivers/duckdb/` | preliminary DuckDB driver (C API) ([README](drivers/duckdb/README.md)) |
| `database:drivers/mock` | `drivers/mock/` | mock driver for tests |
| — | `tools/{scangen,schemagen,querygen,migragen,migranew}/` | code generators + migration scaffolder |
| — | `tools/odb/` | unified CLI (`odb <scan\|schema\|query\|migrate-new\|migrate-gen>`) |
| — | `bindings/sqlite/` | SQLite bindings + static lib |
| — | `bindings/duckdb/` | DuckDB C-API bindings ([README](bindings/duckdb/README.md)) |
| — | `examples/` | runnable examples |

## License

[MIT](LICENSE) © 2026 Adam Shelton

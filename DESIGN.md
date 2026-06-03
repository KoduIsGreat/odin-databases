# odin-databases — Design Notes

A database access toolkit for Odin: a driver-agnostic `sql` core, a typed SQL
builder, and code generators that turn your schema into typed query descriptors
and row scanners.

## Imports — the `database` collection

The repo is an Odin *collection* named `database`, rooted at the repo. Build
with `-collection:database=.` (wired into the justfile and `ols.json`), and
everything imports with rooted paths — no `../..`:

```odin
import sql    "database:sql"
import drv    "database:sql/driver"
import sb     "database:sqlbuilder"
import sqlite "database:drivers/sqlite"
import mock   "database:drivers/mock"
```

Consumers depend on it the same way: `-collection:database=/path/to/this/repo`,
then `import "database:sql"`.

## Architecture

```
sql/                  — package sql (DB, Conn, Rows, Row, Stmt, Tx, scan)
  db.odin             — DB (pool + API), open/close, overload sets, pool internals
  conn.odin           — Conn, checkout, checkin
  rows.odin           — Rows, next, columns, rows_err, close_rows, codegen accessors
  query_row.odin      — Row, query_row, close_row (error-safe)
  stmt.odin           — Stmt, prepare, stmt_exec, stmt_query, close_stmt
  tx.odin             — Tx, begin, commit, rollback (closes conn on error)
  scan.odin           — Generic struct + positional scanning via runtime type info
  types.odin/driver.odin — re-exports of the driver-contract types
  driver/             — package driver: Driver vtable + opaque handles + Value/Error
sqlbuilder/
  builder.odin        — typed SQL builder (descriptors, predicates) + raw escape hatch
migrate/
  migrate.odin        — driver-agnostic migration runner (up/down/to/status)
  loader.odin         — from_dir: load migrations from <version>_<name>.up/.down.sql
drivers/
  sqlite/             — sql.Driver implementation for SQLite (+ loadable extensions)
  postgres/           — pure-Odin sql.Driver for PostgreSQL (v3 wire protocol)
  mock/               — expectation-based mock driver for tests
tools/
  scangen/            — generates concrete row scanners from //+sql:scan structs
  schemagen/          — generates typed column descriptors (+ structs) from
                        //+sql:table structs or a live database
  migragen/           — embeds a directory of .sql migrations into a generated
                        []migrate.Migration (an embedded front-end for migrate)
examples/             — runnable, focused examples (see examples/README.md)
bindings/sqlite/      — generated Odin bindings + static lib for SQLite
```

The project is three cooperating layers:

1. **`sql`** (`database:sql`) — the user-facing API (`DB`, `Conn`, `Rows`,
   `Row`, `Stmt`, `Tx`, `scan`) plus **`sql/driver`** (`database:sql/driver`),
   the vtable struct (`Driver`) and shared types (`Value`, `Error`, `Result`,
   `Column`, `Tx_Options`) that driver authors implement.
2. **`sqlbuilder`** (`database:sqlbuilder`) — a typed SQL builder driven by
   generated column descriptors, with a raw string escape hatch.
3. **`tools/`** — the code generators (`scangen`, `schemagen`) that connect a
   schema (your structs or a live DB) to layers 1 and 2.

Drivers fill in a `Driver` struct of procedure pointers. The sql package only
sees opaque handles (`Conn_Handle`, `Stmt_Handle`, etc., all `distinct rawptr`).
Driver authors cast these to/from their own concrete types internally.

## Key Decisions — sql

### No driver registry — pass the driver directly

The driver is passed explicitly rather than registered in a global map and
looked up by name:

```odin
db, err := sql.open(&sqlite.driver, ":memory:")
```

This keeps things explicit: no global mutable state, no string lookups at
runtime, and the dependency on a concrete driver is visible at the call site.

### Explicit Conn checkout for prepared statements

Connection checkout is a first-class concept rather than hidden behind a
statement cache:

```odin
conn := sql.checkout(db)
defer sql.checkin(&conn)
stmt := sql.prepare(&conn, "SELECT ...")
defer sql.close_stmt(&stmt)
```

The `Stmt` is always bound to a specific `Conn`, so the user sees exactly which
resource they're holding. Convenience `exec`/`query`/`query_row` on `^DB` still
auto-checkout/checkin for the simple case.

### Connection ownership via nil-check on `db` field

`Rows`, `Tx`, and the pool-convenience paths all need to know whether they own
a connection (and should release it on close) or are borrowing one. We use a
single rule: if the `db: ^DB` field is non-nil, the object owns the connection
and releases it; if nil, the caller manages the connection.

| Created via | `db` field | Releases conn? |
|---|---|---|
| `sql.query(db, ...)` | non-nil | yes, on `close_rows` |
| `sql.query(&conn, ...)` | nil | no |
| `sql.query(&tx, ...)` | nil | no |
| `sql.begin(db)` | non-nil | yes, on `commit`/`rollback` |
| `sql.begin(&conn)` | nil | no |
| `sql.query_row(db, ...)` | (n/a, eagerly detached) | yes, inside `query_row` |

Owning objects also store the connection's `created_at` and pass it back to
`pool_release`, so `max_lifetime` evictions fire at the correct time.

### Borrowed value semantics

Values read from rows (`string`, `[]byte` in the `Value` union) point into
driver-owned memory. They are valid only until the next `next()` call or
`close_rows()`. If you need to keep data, copy explicitly — or use `scan()`,
which clones string and `[]byte` data using `context.allocator`.

This matches what underlying C libraries actually do (SQLite's
`sqlite3_column_text` returns a pointer valid until step/finalize). Zero
allocations on the read hot path beyond the per-Rows column buffer (allocated
lazily on the first `next()`).

### Iteration errors (`rows_err`)

`next()` returns a bare `bool`, so — exactly like Go's `rows.Next()` — it
collapses two outcomes into one `false`: a clean end-of-rows, and a failure that
ended iteration early (a dropped connection, a statement timeout, a server-side
error on row *N*). To tell them apart, call `rows_err(&rows)` after the loop; it
returns the error that stopped iteration, or `nil` if the result drained fully.

```odin
for sql.next(&rows) { ... }
if err := sql.rows_err(&rows); err != nil { /* result was truncated */ }
```

A mid-stream error is **terminal**: the driver sets `done` and `next()` returns
`false`, so there are no further rows to "skip past" and lose the error. The
driver stashes the error on its rows handle (`pg_rows.err` / `sqlite_rows.err`);
`next()` captures it into `Rows.err` the moment iteration stops, and nothing ever
clears it. The driver contract is one extra vtable proc, `rows_err(handle) ->
Error` — nil-guarded in `next()`, so a driver that doesn't implement it (e.g.
`mock`) simply reports "no error". As a backstop, `close_rows()` returns
`Rows.err` in preference to any close error, so even a caller that only
`defer`s `close_rows` and checks its return won't silently drop a truncated read.

The error *message* is borrowed under the same rules as row values (postgres
`conn.last_error`, SQLite `errmsg` — valid until the next op on that connection),
so read or copy it before issuing another query on the same conn.

Single-row reads don't need this: `query_row` calls `next` once and surfaces any
error through `Row.err` at `scan` time (see below).

### `query_row` and `Row`

`query_row` is a convenience for single-row reads. Internally it acquires a
connection, runs the query, calls `next` once, *detaches* (clones the borrowed
strings/bytes and releases the conn back to the pool), and returns a `Row`.

```odin
row := sql.query_row(db, "SELECT * FROM users WHERE id = ?", i64(1))
defer sql.close_row(&row)
user: User
if err := sql.scan(&row, &user); err != nil { ... }
```

`Row` is lazy-error: any query or "no rows" failure is held in `row.err` and
surfaced when `scan` is called. The connection is released inside `query_row`,
but the detached `Row` still buffers its cloned column metadata and values, so
`close_row(&row)` is required to free them — hence the `defer sql.close_row(&row)`
idiom. `close_row` is safe whether the row succeeded, errored, or detached —
error rows carry a pre-closed `Rows`, so it never crashes. String/`[]byte`
values that `scan` moves out are owned by the scan destination and outlive
`close_row` (cloned with `context.allocator`, freed by the caller); the column
buffers are freed with `db.allocator` by `close_row`.

### Pool semantics

The pool is mutex-protected and supports blocking acquire:

| Config | Behavior |
|---|---|
| `max_open = 0` (default) | Unlimited; `pool_acquire` never blocks. |
| `max_open > 0` | `pool_acquire` blocks on `sync.Cond` when the cap is reached. |
| `wait_timeout > 0` | Cap on the block. Returns `Pool_Error.Timeout` when exceeded. |
| `wait_timeout = 0` (default) | Wait forever (or until `close`, which returns `Pool_Error.Closed`). |
| `max_idle` | Idle conns above this cap are closed on release; can be lowered via `set_max_idle_conns`, which trims immediately. |
| `max_lifetime` | Conns older than this are closed when re-acquired. |
| `prune_idle(db)` | Closes every currently-idle conn. |

Connections are checked out exclusively — one caller at a time per connection.
Drivers never need to handle concurrent access to a single connection. This
matches how all major database C libraries work (libpq, libmysqlclient, sqlite3
in multi-threaded mode).

`commit`/`rollback` close the connection (via `pool_discard`) on driver error
instead of returning a possibly-poisoned conn to the pool.

### Allocator threading

The `DB` carries an explicit allocator (defaulting to `context.allocator`),
passed at `open` time. All internal allocations flow through it:

- `DB` struct and pool free-list: `db.allocator`
- Driver `open` receives the allocator for Odin-side wrapper structs
- Column-name + row-buffer slices on `Rows`: `db.allocator` (freed on `close_rows`)
- C libraries manage their own memory separately (malloc/free)

`scan()` clones strings and `[]byte` into `context.allocator` at the call site,
so callers can use an arena for scan output independently from pool internals.

### Overloaded API via procedure sets

Odin doesn't have methods, so we use procedure overloading to dispatch on the
first parameter type:

```odin
exec      :: proc{db_exec, conn_exec, tx_exec}
query     :: proc{db_query, conn_query, tx_query}
query_row :: proc{db_query_row, conn_query_row, tx_query_row}
prepare   :: proc{conn_prepare, tx_prepare}
begin     :: proc{db_begin, conn_begin}
```

The user writes `sql.exec(thing, query, args)` regardless of whether `thing` is
`^DB`, `^Conn`, or `^Tx`. Individual implementations are `@(private)`.

### Struct scanning via runtime type info

`scan(rows, &dest)` uses Odin's `runtime.Type_Info_Struct` to match column
names to struct field names at runtime. It handles type coercion (e.g. `i64` →
`int`, `i64` → `bool`) and optional fields: a nullable column scans into a
`Maybe(T)` field — present values set the variant, SQL `NULL` leaves it `None`.
Partial structs work — unmatched columns are skipped, unmatched fields keep
their zero values.

For a faster, allocation-light path, `tools/scangen` generates concrete
`scan_<TypeName>` procs (see below). Odin's overload resolution picks the
concrete generated proc when one exists and falls back to the reflective
`sql.scan_struct` otherwise.

### Thread safety

`DB` is safe to share across threads. `Conn`, `Tx`, `Rows`, `Stmt`, and `Row`
are not — once checked out, they belong to a single thread until returned to
the pool.

### SQLite driver specifics

- `time.Time` binds as ISO-8601 TEXT with nanosecond precision:
  `"YYYY-MM-DD HH:MM:SS.NNNNNNNNN"`. SQLite's date functions ignore the
  fractional suffix, so the format is compatible with `julianday()` etc.
- Columns whose declared type starts with `DATETIME`/`TIMESTAMP`/`DATE`/`TIME`
  (case-insensitive) are read back as `time.Time` — parsed from TEXT (with or
  without fractional seconds), or converted from Unix seconds if INTEGER.
- `Stmt_Handle` wraps a `Sqlite_Stmt{stmt, conn}` so stmt operations can access
  the db handle for `errmsg`/`last_insert_rowid`/`changes` and the conn's
  allocator.
- Transactions use `BEGIN`/`COMMIT`/`ROLLBACK` SQL; `Tx_Handle` is the
  `Sqlite_Conn` pointer (SQLite tx state lives on the connection).
- **Multi-statement `exec`**: a *parameterless* `exec` runs every
  `;`-separated statement in the string (looping `prepare_v2` via its `pzTail`
  out-param), so DDL / migration scripts work. A *parameterized* `exec` (with
  bound args) keeps the single-statement path. This matches the Postgres
  driver, whose parameterless path already runs multi-statement DDL via the
  simple-query protocol.
- **Extensions**: the static lib is built with JSON1, FTS5, R*Tree, and
  column-metadata, so their SQL functions / virtual tables work through normal
  `exec`/`query`. JSON is just TEXT (→ `string`) or, for JSONB, a BLOB
  (→ `[]byte`); parse it with `core:encoding/json`. Run-time loadable
  extensions are supported via `sqlite.enable_load_extension` +
  `sqlite.load_extension` on a checked-out connection (off by default, and
  per-connection — see the proc docs for the pool caveat).

### PostgreSQL driver specifics

The PostgreSQL driver is **pure Odin** — it implements the v3 frontend/backend
wire protocol directly over a `core:net` TCP socket, with no libpq dependency.
This was a deliberate choice: libpq buffers the *entire* result set before
returning, which fights the driver contract's streaming `rows_next` +
borrowed-value model. Reading `DataRow` messages straight off the socket *is*
that streaming model, so the protocol decoder refills one per-`Rows` buffer per
row, exactly like the SQLite driver does with `sqlite3_step`.

- **Auth**: trust, cleartext, MD5, and SCRAM-SHA-256 (the modern default),
  built on `core:crypto` (`pbkdf2`/`hmac`/`sha2`) and `core:encoding/base64`.
  The server signature is verified before the connection is considered open.
- **TLS is opt-in at build time.** `core` ships no TLS, so the default build is
  plaintext-only and pure-Odin (no C dependency); `require`/`verify-*` then error
  with a "rebuild with TLS" message. Building with `-define:DATABASE_PG_TLS=true`
  links OpenSSL (`tls.odin`) and enables `sslmode=require` — encrypt without
  certificate verification. The whole wire surface funnels through `send_all`/
  `recv_exact`, which switch to `SSL_read`/`SSL_write` once `conn.tls` is set
  after the SSLRequest handshake, so nothing else in the driver changes. Cert
  verification (`verify-ca`/`verify-full`) and client certs are still to come;
  a native transport can replace OpenSSL once Odin ships TLS.
- **Placeholders**: the rest of the toolkit (and `sqlbuilder`) emit `?`, but
  PostgreSQL wants `$1, $2, …`. The driver translates `?`→`$n`, skipping `?`
  inside string/identifier literals, dollar-quoted strings, and comments;
  native `$n` passes through untouched. (A bare jsonb `?` operator is the one
  casualty — wrap it in a dollar-quoted string.)
- **Text format**: parameters and results use the text wire format, so the
  driver parses textual values (and hex `bytea`) into the `Value` union, applying
  the same OID→Odin-type affinity choices `schemagen`'s DB mode makes. No binary
  protocol yet.
- **No last-insert id**: PostgreSQL doesn't report one without `RETURNING`, so
  `Result.last_insert_id` is always 0; `rows_affected` comes from the
  CommandComplete tag. Use `RETURNING id` + `query_row` for generated keys.
- **Transactions** use `BEGIN`/`COMMIT`/`ROLLBACK` (with `ISOLATION LEVEL …`
  derived from `Tx_Options`); `Tx_Handle` is the connection pointer, since
  PostgreSQL transaction state lives on the connection — the same shape as the
  SQLite driver.
- **exec vs. query**: parameterless statements use the simple query protocol
  (so multi-statement DDL works); parameterized ones use the extended protocol
  (Parse/Bind/Describe/Execute/Sync). Either way the connection is always
  drained to ReadyForQuery before reuse, so pooled connections stay clean.
- **Advisory locks**: implements the driver's optional `lock`/`unlock` via
  `pg_advisory_lock`/`pg_advisory_unlock` (session-scoped), which the `migrate`
  runner uses to serialize migrations across processes.

## Key Decisions — sqlbuilder

The builder has two layers. The **typed layer** is preferred; the **raw layer**
(`raw_*`, `write`, `param`) is an unchecked string escape hatch for SQL the
typed layer can't yet express.

### Column descriptors carry the Odin type in the type system

The typed layer is driven by `Column(T)` descriptors — normally generated by
`schemagen` — that pair a column's table/name with the Odin type `T` it maps
to, plus a `nullable` flag:

```odin
Column_Base :: struct { table, name: string, type_id: typeid, nullable: bool }
Column      :: struct($T: typeid) { using base: Column_Base }
```

Because you reference generated identifiers (`Users.age`), a mistyped column is
a compile error. Because predicate constructors are generic over the column's
`T`, a wrong-typed value is a compile error too:

```odin
where_(&b, ge(Users.age, 18))   // ge(c: Column($T), v: T); ge(Users.age, "x") won't compile
```

`Column(T)` embeds `Column_Base` via `using`, so it converts implicitly to
`Column_Base` in heterogeneous column lists (`select(&b, Users.id, Users.name)`)
while staying type-checked in single-column predicates.

### Predicates are values; the builder is append-only

`eq`/`ne`/`lt`/`ge`/`like`/`is_null`/… return a `Predicate{sql, args}`, composed
with `and_`/`or_`/`not_`. They allocate with `context.temp_allocator` by
default; `where_`/`set` copy what they need into the builder's own buffer and
args, so predicates need not outlive the call. `to_query` returns the final
`(string, []Value)` for `sql.query(db, q, ..args)`.

### Typed INSERT via `bind`

A typed INSERT can't be a single heterogeneous variadic, so values are bound
per column: `bind(c: Column($T), v: T)` checks the value against the column and
yields a homogeneous `Binding`. `insert_into(&b, Users, bind(Users.name, n),
bind(Users.age, a))` then emits the full `INSERT INTO users (name, age) VALUES
(?, ?)`.

### What the type system can't do

Odin can't compute a result-row type from a dynamic column selection (no
type-level computation), so `select` doesn't produce a tailored row type — you
scan into a struct (generated or hand-written) as usual. The descriptors give
compile-time safety on **names** and **predicate value types**; the query is
still assembled dynamically at runtime.

## Key Decisions — code generation

Two single-responsibility generators share the idea of reading a schema and
emitting Odin source. They compose: run `schemagen` then `scangen`.

### scangen — concrete row scanners

For each struct annotated `//+sql:scan`, `scangen` emits a `scan_<TypeName>`
proc into `<pkg>/scan.gen.odin`, plus a `scan` overload set that lists the
generated procs first and the reflective `sql.scan_*` procs as fallbacks. A
`Maybe(T)` field is unwrapped to `T` for the generated assignment, which
converts implicitly back into the optional — so the same emitted code handles
plain and nullable fields, and a SQL `NULL` leaves the field `None`.

### schemagen — typed descriptors, from structs or a database

`schemagen` is built around an internal `Schema` model that decouples the
*source* of the schema from the *emitted* code. The front-ends populate the
same model and share one emitter:

- **Struct front-end** (`schemagen <dir>`): reads structs annotated
  `//+sql:table <name>`. The struct is the source of truth, so only descriptors
  are emitted. A `Maybe(T)` field marks the column nullable. Driver-agnostic.
- **SQLite DB front-end** (`schemagen -db=<path> <dir>`, the default): opens the
  database via the driver, lists tables via `PRAGMA table_list`, and reads
  `PRAGMA table_info`. The database is the source of truth, so it emits **both**
  row structs and descriptors (unless `-structs=none`). `table_list` (not
  `sqlite_master`) is used so views and the shadow tables that virtual tables
  (FTS5, R*Tree) create are skipped — only real and virtual tables in the main
  schema are emitted, sorted for deterministic output.
- **PostgreSQL DB front-end** (`schemagen -driver=postgres -db=<dsn> <dir>`):
  opens a live server via the pure-Odin postgres driver and introspects
  `information_schema` — `tables` (base tables in the `public` schema only;
  views are skipped, server-sorted for deterministic output) and `columns`
  (`column_name`, `udt_name`, `is_nullable`, by `ordinal_position`). Emits the
  same row-struct + descriptor output as the SQLite front-end.

The SQLite DB front-end maps SQLite declared types to the Odin types the driver
produces at scan time — applying SQLite's affinity rules (`INT*`→`i64`,
`CHAR/TEXT/CLOB`→`string`, `BLOB`→`[]byte`, `REAL/FLOA/DOUB`→`f64`), the same
datetime detection (`DATETIME`/`TIMESTAMP`/`DATE`/`TIME`→`time.Time`) as the
driver, and special cases for types whose NUMERIC affinity would otherwise
mislead: `JSON`→`string` (`JSONB`→`[]byte`) and `BOOLEAN`→`bool`. A `NUMERIC`/
`DECIMAL` column defaults to `f64`; since such a column may store integers
(returned as `i64`), the scan layer widens `i64`→`f64`/`f32` so it still scans
into a float field.

The PostgreSQL front-end maps each column's canonical `udt_name` to the Odin
type the driver produces, mirroring its OID mapping: `int2`/`int4`/`int8`/`oid`
→`i64`, `float4`/`float8`/`numeric`/`decimal`→`f64`, `bool`→`bool`,
`bytea`→`[]byte`, the `date`/`time`/`timetz`/`timestamp`/`timestamptz` family
→`time.Time`, and everything textual (`text`/`varchar`/`bpchar`/`char`/`name`/
`uuid`/`json`/`jsonb`, plus any unrecognized / user-defined type the driver
returns as text)→`string`. (`json`/`jsonb` map to `string` here, not `[]byte`
as in SQLite, because the postgres driver reads them back in the text format.)

### Nullability

A column is nullable unless `NOT NULL` or part of the primary key. Nullable
columns map to `Maybe(T)` struct fields and set `nullable = true` on the
descriptor; the descriptor's `Column(T)` always uses the base type `T` (the
nullability is metadata). Both the reflective scanner and scangen scan a `NULL`
into a `Maybe(T)` field as `None`.

### DB-mode struct naming (`-structs`)

- `singular` (default): the row struct is the singularized, PascalCased table
  name (`users`→`User`, `categories`→`Category`). If that collides with the
  descriptor (a singular table like `user`), `_Row` is appended and a warning is
  printed. The singularizer is a heuristic — irregular plurals can be fixed by
  editing the generated file or using `-structs=none`.
- `none`: no row structs are emitted (descriptors only). This suits the common
  case where only some columns are relevant — define your own, often partial,
  struct and scan into it.

Generated row structs are tagged `//+sql:scan`, so running `scangen` after
`schemagen` produces concrete scanners for them.

## Key Decisions — migrate

`database:migrate` is a thin migration runner layered on the `sql` core. It
reuses the same decoupling idea as `schemagen`: the runner consumes a
`[]Migration` slice and doesn't care where it came from.

### The runner consumes a slice; sources are front-ends

`up`/`down`/`to`/`status` all take `(db: ^sql.DB, migrations: []Migration)`. A
`Migration` is just `{version, name, up, down}` where `up`/`down` are SQL
strings. There are two front-ends that produce the slice, neither of which the
runner knows about:

- **`from_dir`** loads `.sql` files at runtime.
- **`migragen`** (`tools/migragen`) embeds the same `.sql` files into a generated
  `migrations.gen.odin` at build time, so the binary is self-contained. It is
  literally `from_dir` plus an Odin emitter, and slots into the existing codegen
  story — the generated file is committed and CI fails on drift, exactly like
  scangen/schemagen.

Building the slice by hand works too. This keeps the `sql` core untouched and
makes the runner trivially testable against the mock or an in-memory SQLite
database.

### State: one row per applied version

A `schema_migrations(version BIGINT PK, name TEXT, applied_at TIMESTAMP)` table
records each applied migration (not just a single "current version" marker), so
the full history is queryable and `status` can report per-migration state. The
DDL is portable `CREATE TABLE IF NOT EXISTS` — `BIGINT`/`TEXT`/`TIMESTAMP` are
native to both SQLite and PostgreSQL — so it is safe to run on every startup.

### Atomicity via one transaction per migration

Each migration's body and its `schema_migrations` row are applied inside a
single `sql.begin`/`commit`. Both drivers have transactional DDL, so a failed
migration rolls back cleanly and leaves no half-applied state. This is also why
the SQLite driver's parameterless `exec` had to run multi-statement scripts (see
*SQLite driver specifics*): a migration body is usually several statements, and
they must all run within the one transaction.

### Timestamp versioning, reversible by default

Versions are `i64` and, by the `from_dir` convention, 14-digit `YYYYMMDDHHMMSS`
timestamps — so ordering is by creation time and two branches rarely collide on
a number. Migrations are reversible: a `.down.sql` (or non-empty `down` field)
lets `down`/`to` roll back; an empty `down` marks a migration irreversible and
rolling back past it returns `Migrate_Error.Irreversible`.

### Error model: a wrapping union

`migrate.Error` is `union { sql.Error, Migrate_Error }`. DB/driver failures
surface as the wrapped `sql.Error`; migration-specific problems (bad filename,
duplicate version, missing up, irreversible, unknown version) are a
`Migrate_Error`. The driver-contract `Error` union is closed and can't be
extended, so wrapping — rather than adding variants — keeps that contract intact.

### Concurrency: advisory lock when the driver supports it

`up`/`down`/`to` run on a single checked-out `Conn` for the whole operation, and
— when the driver implements the optional `lock`/`unlock` contract — take a
session advisory lock (keyed by `LOCK_KEY`) around the run. So if several app
instances boot and call `up` at once, the first acquires the lock and migrates
while the rest block, then wake to find everything applied and no-op. Without
this they would race and the losers would fail on the duplicate `version` insert
(or, worse, double-run a non-idempotent migration).

The lock is a property of the *driver*, not the runner: the migrate package only
calls `sql.advisory_lock`/`unlock`, which dispatch to the driver's procs.
PostgreSQL implements them via `pg_advisory_lock` (session-scoped — hence the
single-`Conn` requirement); SQLite leaves them nil (it is single-writer, so the
runner skips locking and relies on SQLite's own write serialization). The
read-only `status`/`current_version` take no lock.

This is why the `Driver` vtable gained two *optional* (nil-able) procs rather
than a required pair: adding them is backward compatible (omitted fields
zero-init to nil), and `supports_advisory_lock` is just a nil check.

## Open Questions

- **Per-Conn column metadata caching**: `[]Column` is allocated per-Rows and
  freed on close. For long-running queries this is fine; for many short queries
  the allocation could be amortized via a `Conn`/`Stmt` cache.
- **Batch insert**: No `exec_many` API yet. Could wrap `[][]Value` in a tx.
- **Cancellation/timeouts**: There is a per-call `wait_timeout` for pool
  acquire, but no driver-level query cancellation.
- **Named parameters**: Currently positional (`?`) only. Named (`:name`) would
  require driver support and a different bind API.
- **Connection health on checkout**: `reset` is in the vtable but the pool
  doesn't proactively validate connections. Lazy validation could be added.
- **Richer compile-time projections in sqlbuilder**: joins are typed via column
  descriptors, but result projections still scan into a separately-defined
  struct; computing a projection's row type isn't expressible in Odin's type
  system.
- **Irregular pluralization in schemagen**: the singularizer is heuristic; a
  per-table name override could be added if needed.
- **Out-of-order migrations**: `up` applies any unrecorded version in ascending
  order, including one whose timestamp precedes an already-applied migration. A
  strict mode could reject such gaps.
- **Migration lock key collisions**: the advisory lock uses a single fixed
  `LOCK_KEY`. An app already using that key for its own advisory locks would
  contend; a configurable key could be exposed if needed.

# odin-databases — Design Notes

A database access toolkit for Odin: a driver-agnostic `database/sql` core, a
typed SQL builder, and code generators that turn your schema into typed query
descriptors and row scanners.

## Architecture

```
database/
  sql/
    driver.odin     — re-export of driver-contract types
    types.odin      — re-export of Value, Error, Result, Column, Tx_Options
    db.odin         — DB (pool + API), open/close, overload sets, pool internals
    conn.odin       — Conn, checkout, checkin
    rows.odin       — Rows, next, columns, close_rows, codegen accessors
    query_row.odin  — Row, query_row, close_row (error-safe)
    stmt.odin       — Stmt, prepare, stmt_exec, stmt_query, close_stmt
    tx.odin         — Tx, begin, commit, rollback (closes conn on error)
    scan.odin       — Generic struct + positional scanning via runtime type info
    driver/
      driver.odin   — Driver vtable + opaque handles
      types.odin    — Value / Error union + variants
  sqlbuilder/
    builder.odin    — typed SQL builder (descriptors, predicates) + raw escape hatch
drivers/
  sqlite/driver.odin — sql.Driver implementation for SQLite
  mock/              — expectation-based mock driver for tests
tools/
  scangen/           — generates concrete row scanners from //+sql:scan structs
  schemagen/         — generates typed column descriptors (+ structs) from
                       //+sql:table structs or a live database
examples/            — runnable, focused examples (see examples/README.md)
```

The project is three cooperating layers:

1. **`database/sql`** — the user-facing API (`DB`, `Conn`, `Rows`, `Row`,
   `Stmt`, `Tx`, `scan`) plus **`database/sql/driver`**, the vtable struct
   (`Driver`) and shared types (`Value`, `Error`, `Result`, `Column`,
   `Tx_Options`) that driver authors implement.
2. **`database/sqlbuilder`** — a typed SQL builder driven by generated column
   descriptors, with a raw string escape hatch.
3. **`tools/`** — the code generators (`scangen`, `schemagen`) that connect a
   schema (your structs or a live DB) to layers 1 and 2.

Drivers fill in a `Driver` struct of procedure pointers. The sql package only
sees opaque handles (`Conn_Handle`, `Stmt_Handle`, etc., all `distinct rawptr`).
Driver authors cast these to/from their own concrete types internally.

## Key Decisions — database/sql

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

### `query_row` and `Row`

`query_row` is a convenience for single-row reads. Internally it acquires a
connection, runs the query, calls `next` once, *detaches* (clones the borrowed
strings/bytes and releases the conn back to the pool), and returns a `Row`.

```odin
row := sql.query_row(db, "SELECT * FROM users WHERE id = ?", i64(1))
user: User
if err := sql.scan(&row, &user); err != nil { ... }
```

`Row` is lazy-error: any query or "no rows" failure is held in `row.err` and
surfaced when `scan` is called. `close_row(&row)` is safe whether the row
succeeded, errored, or detached — error rows carry a pre-closed `Rows` so the
common `defer sql.close_row(&row)` idiom never crashes.

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
*source* of the schema from the *emitted* code. Two front-ends populate the
same model and share one emitter:

- **Struct front-end** (`schemagen <dir>`): reads structs annotated
  `//+sql:table <name>`. The struct is the source of truth, so only descriptors
  are emitted. A `Maybe(T)` field marks the column nullable.
- **DB front-end** (`schemagen -db=<path> <dir>`): opens the database via the
  driver, lists tables from `sqlite_master`, and reads `PRAGMA table_info`. The
  database is the source of truth, so it emits **both** row structs and
  descriptors (unless `-structs=none`).

The DB front-end maps SQLite declared types to the Odin types the driver
produces at scan time — applying SQLite's affinity rules (`INT*`→`i64`,
`CHAR/TEXT/CLOB`→`string`, `BLOB`→`[]byte`, `REAL/FLOA/DOUB`→`f64`) and the same
datetime detection (`DATETIME`/`TIMESTAMP`/`DATE`/`TIME`→`time.Time`) as the
driver, so generated types match scan results.

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

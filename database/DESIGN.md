# database/sql — Design Notes

A standardized database access package for Odin, inspired by Go's `database/sql`.

## Architecture

Two-layer design:
- **`database/sql`** — User-facing API: `DB`, `Conn`, `Rows`, `Stmt`, `Tx`, `scan`
- **`database/sql/Driver`** — Vtable struct that driver authors implement

Drivers fill in a `Driver` struct of procedure pointers. The sql package only sees
opaque handles (`Conn_Handle`, `Stmt_Handle`, etc., all `distinct rawptr`). Driver
authors cast these to/from their own concrete types internally.

```
database/
  sql/
    driver.odin     — Driver vtable, opaque handles
    types.odin      — Value, Error, Result, Column, Tx_Options
    db.odin         — DB (pool + API), open, close, overload sets
    conn.odin       — Conn, checkout, checkin
    rows.odin       — Rows, next, columns, close_rows
    stmt.odin       — Stmt, prepare, stmt_exec, stmt_query, close_stmt
    tx.odin         — Tx, begin, commit, rollback
    scan.odin       — Generic struct scanning via runtime type info
  sqlite/
    bindings.odin   — Minimal SQLite3 C bindings
    driver.odin     — sql.Driver implementation for SQLite
```

## Key Decisions

### No driver registry — pass the driver directly

Go uses `sql.Register("postgres", drv)` + `sql.Open("postgres", dsn)` with a global
mutable map. We pass the driver explicitly:

```odin
db, err := sql.open(&sqlite.driver, ":memory:")
```

More explicit, no global mutable state, no string lookups at runtime.

### Explicit Conn checkout for prepared statements

Go's `DB.Prepare` hides connection management — it lazily prepares on whatever
connection is available, caching per-connection handles. This is clever but adds
significant complexity (cache synchronization, close-all-handles-on-stmt-close,
prefer-connections-that-have-the-stmt).

We expose connection checkout as a first-class concept:

```odin
conn := sql.checkout(db)
defer sql.checkin(&conn)
stmt := sql.prepare(&conn, "SELECT ...")
defer sql.close_stmt(&stmt)
```

The `Stmt` is always bound to a specific `Conn`. The user sees exactly what resource
they're holding. `Conn` and `Stmt` have independent lifetimes managed by the caller.

Convenience `exec`/`query` on `^DB` still auto-checkout/checkin for the simple case.

### Connection ownership via nil-check on `db` field

`Rows`, `Tx`, and the pool-convenience paths all need to know whether they own a
connection (and should release it on close) or are borrowing one. We use a single
rule: if the `db: ^DB` field is non-nil, the object owns the connection and releases
it. If nil, the caller manages the connection.

| Created via | `db` field | Releases conn? |
|---|---|---|
| `sql.query(db, ...)` | non-nil | yes, on `close_rows` |
| `sql.query(&conn, ...)` | nil | no |
| `sql.query(&tx, ...)` | nil | no |
| `sql.begin(db)` | non-nil | yes, on `commit`/`rollback` |
| `sql.begin(&conn)` | nil | no |

### Borrowed value semantics

Values read from rows (`string`, `[]byte` in the `Value` union) point into
driver-owned memory. They are valid only until the next `next()`/`scan()` call or
`close_rows()`. If you need to keep data, copy explicitly.

This matches what underlying C libraries actually do (SQLite's `sqlite3_column_text`
returns a pointer valid until step/finalize). Zero allocations on the read hot path.

**Consequence**: `Row`/`scan`-then-auto-close patterns (like Go's `QueryRow().Scan()`)
are incompatible — closing invalidates the borrowed pointers before the caller reads
them. We removed `Row`/`query_row` in favor of the explicit pattern:

```odin
rows := sql.query(db, "SELECT ...", args)
defer sql.close_rows(&rows)
if sql.next(&rows, dest[:]) { /* use dest */ }
```

Or with `scan`:

```odin
rows := sql.query(db, "SELECT ...", args)
defer sql.close_rows(&rows)
user: User
if sql.scan(&rows, &user) { /* use user */ }
```

### Allocator threading

The `DB` carries an explicit allocator (defaulting to `context.allocator`), passed
at `open` time. All internal allocations flow through it:

- `DB` struct and pool free-list: `db.allocator`
- Driver `open` receives the allocator for Odin-side wrapper structs
- Column metadata slices: allocated from `conn.allocator`, freed on `rows_close`
- C libraries manage their own memory separately (malloc/free)

Query results don't allocate — borrowed semantics mean `next()`/`scan()` write
pointers into driver-owned memory.

### Overloaded API via procedure sets

Odin doesn't have methods, so we use procedure overloading to dispatch on the
first parameter type:

```odin
exec    :: proc{db_exec, conn_exec, tx_exec}
query   :: proc{db_query, conn_query, tx_query}
prepare :: proc{conn_prepare, tx_prepare}
begin   :: proc{db_begin, conn_begin}
```

The user writes `sql.exec(thing, query, args)` regardless of whether `thing` is
`^DB`, `^Conn`, or `^Tx`. Individual implementations are `@(private)`.

### Struct scanning via runtime type info

`scan(rows, &dest)` uses Odin's `runtime.Type_Info_Struct` to match column names
to struct field names at runtime. Handles type coercion (e.g., `i64` → `int`,
`i64` → `bool`). Partial structs work — unmatched columns are skipped, unmatched
fields keep zero values.

### Thread safety

The pool (`DB`) is mutex-protected. Connections are checked out exclusively — one
caller at a time per connection. Drivers never need to handle concurrent access to
a single connection. This matches how all major database C libraries work (libpq,
libmysqlclient, sqlite3 in multi-threaded mode).

### SQLite driver specifics

- `time.Time` binds as ISO-8601 TEXT (`"YYYY-MM-DD HH:MM:SS"`)
- Columns with `DATETIME`/`TIMESTAMP`/`DATE`/`TIME` declared types are read back
  as `time.Time` (parsed from TEXT, or converted from Unix seconds if INTEGER)
- `Stmt_Handle` wraps a `Sqlite_Stmt{stmt, conn}` so stmt operations can access
  the db handle for `errmsg`/`last_insert_rowid`/`changes` and the conn's allocator
- Transactions use `BEGIN`/`COMMIT`/`ROLLBACK` SQL; `Tx_Handle` is just the
  `Sqlite_Conn` pointer (SQLite tx state lives on the connection)

## Open Questions

- **`rows_columns` allocation**: The `[]Column` slice is currently allocated per-Rows
  and freed on close. For long-running queries with many rows, this is fine. But
  should column metadata be cached on the `Conn` or `Stmt` level?
- **Batch insert**: No batch/bulk insert API yet. Could add `exec_many` that takes
  `[][]Value` and wraps in a transaction.
- **Context/cancellation**: Go's `database/sql` uses `context.Context` for timeouts
  and cancellation. Odin has no equivalent. Could add a timeout field to operations.
- **Named parameters**: Currently positional (`?`) only. Named (`:name`) would
  require driver support and a different bind API.
- **Connection health**: `ping` and `reset` are in the vtable but the pool doesn't
  proactively validate connections. Lazy validation on checkout (via `reset`) could
  be added.

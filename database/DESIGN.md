# database/sql — Design Notes

A standardized database access package for Odin, inspired by Go's `database/sql`.

## Architecture

Two-package split:
- **`database/sql`** — User-facing API: `DB`, `Conn`, `Rows`, `Row`, `Stmt`, `Tx`, `scan`.
- **`database/sql/driver`** — Vtable struct (`Driver`) and shared types (`Value`,
  `Error`, `Result`, `Column`, `Tx_Options`) that driver authors implement.

Drivers fill in a `Driver` struct of procedure pointers. The sql package only
sees opaque handles (`Conn_Handle`, `Stmt_Handle`, etc., all `distinct rawptr`).
Driver authors cast these to/from their own concrete types internally.

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
drivers/
  sqlite/driver.odin — sql.Driver implementation for SQLite
  mock/              — expectation-based mock driver for tests
```

## Key Decisions

### No driver registry — pass the driver directly

Go uses `sql.Register("postgres", drv)` + `sql.Open("postgres", dsn)` with a
global mutable map. We pass the driver explicitly:

```odin
db, err := sql.open(&sqlite.driver, ":memory:")
```

More explicit, no global mutable state, no string lookups at runtime.

### Explicit Conn checkout for prepared statements

Go's `DB.Prepare` hides connection management — it lazily prepares on whatever
connection is available, caching per-connection handles. We expose connection
checkout as a first-class concept instead:

```odin
conn := sql.checkout(db)
defer sql.checkin(&conn)
stmt := sql.prepare(&conn, "SELECT ...")
defer sql.close_stmt(&stmt)
```

The `Stmt` is always bound to a specific `Conn`. The user sees exactly what
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
names to struct field names at runtime. Handles type coercion (e.g., `i64` →
`int`, `i64` → `bool`). Partial structs work — unmatched columns are skipped,
unmatched fields keep zero values.

A codegen tool (`tools/scangen`) emits concrete `scan_<TypeName>` procs for
structs annotated with `//+sql:scan`. Odin's overload resolution picks the
concrete generated proc when one exists, and falls back to the reflective
`sql.scan_struct` otherwise.

### Thread safety

`DB` is safe to share across threads. `Conn`, `Tx`, `Rows`, `Stmt`, and `Row`
are not — once checked out, they belong to a single goroutine-equivalent until
returned to the pool.

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

## Open Questions

- **Per-Conn column metadata caching**: `[]Column` is allocated per-Rows and
  freed on close. For long-running queries this is fine; for many short queries
  the allocation could be amortized via a `Conn`/`Stmt` cache.
- **Batch insert**: No `exec_many` API yet. Could wrap `[][]Value` in a tx.
- **Context/cancellation**: Go's `database/sql` uses `context.Context` for
  timeouts and cancellation. Odin has no equivalent; we have a per-call
  `wait_timeout` for pool acquire but no driver-level cancellation.
- **Named parameters**: Currently positional (`?`) only. Named (`:name`) would
  require driver support and a different bind API.
- **Connection health on checkout**: `reset` is in the vtable but the pool
  doesn't proactively validate connections. Lazy validation could be added.

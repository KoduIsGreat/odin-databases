# duckdb — a preliminary DuckDB driver for `database:sql`

A first-cut driver that wires [DuckDB](https://duckdb.org) into the
driver-agnostic `database:sql` core via DuckDB's stable C API (the
[`database:bindings/duckdb`](../../bindings/duckdb) package).

```odin
import sql  "database:sql"
import duck "database:drivers/duckdb"

db, err := sql.open(&duck.driver, ":memory:")   // or a file path, e.g. "app.duckdb"
defer sql.close(db)

sql.exec(db, "CREATE TABLE users (id INTEGER, name VARCHAR, age INTEGER)")
sql.exec(db, "INSERT INTO users VALUES (?, ?, ?)", i64(1), "Alice", i64(30))

rows, _ := sql.query(db, "SELECT id, name, age FROM users WHERE age >= ?", i64(18))
defer sql.rows_close(&rows)
for sql.next(&rows) {
    id, age: i64
    name: string
    sql.scan(&rows, &id, &name, &age)
}
```

## Setup

The driver links DuckDB **statically** from pre-compiled archives that are
**not** checked into the repo (~100MB). Fetch them for your host first:

```sh
just duckdb-lib                 # or: bash bindings/duckdb/fetch_libs.sh
```

Binaries are self-contained (no loader path at run time, +~50MB binary size);
see [`bindings/duckdb`](../../bindings/duckdb/README.md) for where the archives
come from. Run the test suite, or the runnable
[`examples/duckdb`](../../examples/duckdb) demo, with:

```sh
just test-duckdb           # the driver's test suite
just run-duckdb-example    # the examples/duckdb demo
```

## What works

- Connection lifecycle, `exec` / `query`, prepared statements (`prepare` +
  `stmt_exec` / `stmt_query`), and transactions (`begin` / `commit` /
  `rollback`).
- Parameter binding for `bool`, `i64`, `i128` (`HUGEINT`), `u128` (`UHUGEINT`),
  `f64`, `string`, `[]byte`, and `time.Time` (bound as a microsecond
  `TIMESTAMP`); `NULL` via the scan/`Maybe` machinery.
- Reads go through DuckDB's modern **data-chunk / vector API**
  (`duckdb_fetch_chunk`): per-column vector pointers are cached once per chunk,
  so the hot path does no per-cell metadata lookups and no per-cell allocation;
  `VARCHAR`/`BLOB` cells are borrowed straight out of the chunk.
- Column type mapping, all lossless:
  - `BOOLEAN` → `bool`; `TINYINT`…`UINTEGER` → `i64`.
  - `UBIGINT` / `HUGEINT` → `i128`, `UHUGEINT` → `u128` (no precision loss).
  - `FLOAT` / `DOUBLE` → `f64`.
  - `DECIMAL` → exact: scan into `string` for the exact text, `f64` for
    convenience (lossy by choice), or `i128` for the unscaled value.
  - `VARCHAR` → `string`, `BLOB` → `[]byte`.
  - `TIMESTAMP` / `TIMESTAMP_S` / `_MS` / `_NS` / `TIMESTAMP_TZ` / `DATE` /
    `TIME` / `TIME_TZ` → `time.Time`, each decoded at its correct unit;
    `TIMESTAMP_TZ` / `TIME_TZ` fold the zone offset into the UTC instant.
  - `UUID` → canonical `string` (or `[16]u8`); `ENUM` → its label `string`;
    `INTERVAL` → a readable `string` or the typed `duckdb.Interval`.
  - Composites scan structurally into native Odin types: `LIST` → `[]T`,
    `ARRAY` → `[N]T`, `STRUCT` → a struct matched by field name, `MAP` →
    `map[K]V` or `[]struct{key, value}`, `UNION` → a struct of its members
    (inactive ones `None`), nested arbitrarily. A NULL element/field scans as the destination's
    zero value, or as `None` into a `Maybe(T)` element. (Scan a top-level
    `STRUCT`/`UNION` column through a wrapper field — a lone struct destination
    hits scan's reflective column-name-matching path, the same caveat as a lone
    `time.Time`.)
  - `BIT` → a `'0'/'1'` `string`; `VARINT` → its exact decimal `string`
    (arbitrary precision).
- Multi-statement parameterless `exec` runs every `;`-separated statement, so
  DDL / migration scripts work.
- **Bulk insert via the `Appender`** — DuckDB's fast path for loading many rows,
  far quicker than row-by-row `INSERT` (driver-specific, beyond the `sql.Driver`
  contract):

  ```odin
  conn, _ := sql.checkout(db)
  defer sql.checkin(&conn)
  app, _ := duck.appender(&conn, "trades")   // optional schema arg
  for tr in trades {
      duck.append_row(&app, tr.id, tr.symbol, tr.price)  // values in column order
  }
  duck.appender_close(&app)                  // flushes remaining rows
  ```

  `append_value` pushes one value; `end_row` / `flush` / `append_default` are
  available for finer control. The Appender borrows the connection for its
  lifetime and targets one table.

## Preliminary — known limitations

This is an early driver; the rough edges are deliberate, not hidden:

- **Eager results (no streaming).** `duckdb_query` / `execute_prepared`
  materialize the whole result; `fetch_chunk` then walks that buffer, so large
  result sets are held fully in memory. This is **blocked on DuckDB's C API**,
  not a quick TODO: the only functions that yield a non-materialized result
  (`duckdb_pending_prepared_streaming` / `duckdb_stream_fetch_chunk`) are
  deprecated and scheduled for removal, and the supported pending API still
  materializes. The chunk reader is already incremental, so whenever DuckDB
  ships a stable streaming path the change is small (swap the execution call and
  wire up `rows_err`). Until then, bound memory with `LIMIT`/`OFFSET` (or keyset)
  pagination.
- **Binding the exotic types as parameters isn't supported** — a
  `DECIMAL`/`UUID`/`INTERVAL`/composite query argument should be passed as a
  string/literal and `CAST`. Reading them back works as above.
- **Scanned composite memory is caller-owned.** A scanned `[]T` (and any nested
  slices/strings within it) is allocated with `context.allocator`; free it
  yourself, like any scanned string.
- **`last_insert_id` is always 0** — DuckDB has no rowid / last-insert concept.
  Use `RETURNING` (works through the normal query path).
- **Isolation levels are ignored.** `begin` starts DuckDB's snapshot-isolated
  transaction regardless of the requested `Isolation_Level` / `read_only`.
- **No advisory locking** (the optional `lock` / `unlock` contract is left nil),
  so the `migrate` runner proceeds without cross-process locking.
- **Connection model.** A **file** DSN opens a single DuckDB *database* shared by
  every pooled connection (each connection is its own DuckDB *session*), so a
  file-backed pool runs multiple connections concurrently. The shared instance is
  reference-counted in a process-global cache, keyed by DSN, and closed when its
  last connection is released — this is also what avoids DuckDB's single-instance
  file-lock collision when the pool opens a second connection.
- **In-memory pooling.** A `:memory:` DSN is **not** shared: DuckDB makes every
  in-memory open an isolated database, and the driver keeps that (so two unrelated
  `sql.open(":memory:")` calls don't collide). The cost is that a `:memory:` pool
  can't share state across connections — call `sql.set_max_open_conns(db, 1)`, or
  use a file DSN.

Contributions that add streaming, fill in the composite/exotic types (via
`Custom_Value`), or implement advisory locking are welcome.

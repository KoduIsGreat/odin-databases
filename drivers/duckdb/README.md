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

The driver links a prebuilt `libduckdb` shared library that is **not** checked
into the repo (~50MB). Fetch the official one for your host first:

```sh
just duckdb-lib                 # or: bash bindings/duckdb/fetch_libs.sh
```

Because the library is linked dynamically, the loader must find it at run time.
The `just` recipes set `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH` for you; running a
binary by hand, set it yourself (see
[`bindings/duckdb`](../../bindings/duckdb/README.md)). Run the test suite with:

```sh
just test-duckdb
```

## What works

- Connection lifecycle, `exec` / `query`, prepared statements (`prepare` +
  `stmt_exec` / `stmt_query`), and transactions (`begin` / `commit` /
  `rollback`).
- Parameter binding for `bool`, `i64`, `f64`, `string`, `[]byte`, and
  `time.Time` (bound as a microsecond `TIMESTAMP`); `NULL` via the scan/`Maybe`
  machinery.
- Result columns mapped to `bool`, `i64`, `f64`, `string`, `[]byte`, and
  `time.Time` (TIMESTAMP/DATE/TIME). Multi-statement parameterless `exec` runs
  every `;`-separated statement, so DDL / migration scripts work.

## Preliminary — known limitations

This is an early driver; the rough edges are deliberate, not hidden:

- **Eager results, deprecated value API.** `duckdb_query` /
  `execute_prepared` materialize the entire result in memory, and cells are read
  through DuckDB's stable-but-"deprecated" `value_*` convenience functions rather
  than the faster data-chunk / vector API. Correct, but not the fast path, and
  large result sets are fully buffered.
- **Wide integers.** `UBIGINT` / `HUGEINT` are read via `i64`, so very large
  values can lose precision. Unmodeled/exotic types fall back to their `VARCHAR`
  rendering.
- **`last_insert_id` is always 0** — DuckDB has no rowid / last-insert concept.
- **Isolation levels are ignored.** `begin` starts DuckDB's snapshot-isolated
  transaction regardless of the requested `Isolation_Level` / `read_only`.
- **No advisory locking** (the optional `lock` / `unlock` contract is left nil),
  so the `migrate` runner proceeds without cross-process locking.
- **In-memory pooling.** Each pooled connection opens its own DuckDB database, so
  a `:memory:` DSN gives each connection an *isolated* in-memory database (same
  caveat as the SQLite driver). For shared in-memory state across a pool, call
  `sql.set_max_open_conns(db, 1)` or use a file DSN.

Contributions that move the read path onto the data-chunk API, add streaming,
or fill in the wide-integer / temporal-type gaps are welcome.

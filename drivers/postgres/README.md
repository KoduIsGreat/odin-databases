# database:drivers/postgres

A **pure-Odin** PostgreSQL driver for `database:sql` — it speaks the v3
frontend/backend wire protocol directly over a TCP socket (`core:net`), with no
libpq dependency. Use it like any other driver:

```odin
import sql "database:sql"
import pg  "database:drivers/postgres"

db, err := sql.open(&pg.driver, "postgres://user:pass@localhost:5432/mydb?sslmode=disable")
defer sql.close(db)
```

## DSN

Either a URL or libpq-style keyword/value pairs:

```
postgres://user:password@host:port/dbname?sslmode=disable
postgresql://user@localhost/mydb
host=localhost port=5432 user=u password=p dbname=d sslmode=disable
```

Recognized keys: `host`/`hostaddr`, `port`, `user`, `password`,
`dbname`/`database`, `sslmode`. Defaults: `host=localhost`, `port=5432`,
`user=postgres`, `dbname=<user>`.

## What works

- **Auth**: trust, cleartext, MD5, and **SCRAM-SHA-256** (the modern default).
- **Queries**: `exec`, `query`, `query_row`, prepared statements, transactions
  (with isolation levels), all through the standard `database:sql` API.
- **Placeholders**: write `?` (translated to `$1, $2, …`) *or* native `$n` —
  both work. `?` inside string literals, quoted identifiers, dollar-quoted
  strings, and comments is left alone.
- **Streaming**: rows are decoded one `DataRow` at a time and borrow the
  connection's read buffer, matching the driver contract's borrowed-value
  semantics (`sql.scan` clones what you keep).
- **Types** (TEXT wire format): `bool`, the int family → `i64`, `float4/8` and
  `numeric` → `f64`, `bytea` → `[]byte`, `date`/`time`/`timestamp`/`timestamptz`
  → `time.Time`, everything textual (incl. `json`/`jsonb`/`uuid`) → `string`.

## Limitations (v1)

- **No TLS yet.** Connect with `sslmode=disable` (or to a local / self-hosted
  server that allows plaintext). `sslmode=require` / `verify-ca` / `verify-full`
  return an error. A TLS transport (initially via OpenSSL bindings) is planned.
- **No last-insert id.** PostgreSQL doesn't report one without `RETURNING`, so
  `Result.last_insert_id` is always `0`. Use `RETURNING id` + `query_row`:

  ```odin
  row := sql.query_row(db, "INSERT INTO users (name) VALUES (?) RETURNING id", "Alice")
  id: i64
  sql.scan(&row, &id)
  ```

- **`?` jsonb operator.** A bare `?` outside quotes is always treated as a
  placeholder, so the jsonb `?`/`?|`/`?&` operators must be wrapped in a
  dollar-quoted string or expressed via the equivalent functions.
- Parameters/results use the **text** format (no binary protocol yet), and
  query cancellation / statement timeouts are not implemented.

## Testing

The integration tests in `driver_test.odin` run only when `ODIN_PG_TEST_DSN`
points at a reachable server; otherwise they skip. A throwaway server is one
command away:

```sh
just postgres-docker        # starts postgres:17 on host port 55432
just test-postgres 'postgres://odin:secret@localhost:55432/odintest?sslmode=disable'
just postgres-docker-stop   # cleanup
```

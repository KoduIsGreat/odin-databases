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

## Code generation

Both generators work with this driver:

- **scangen** is driver-agnostic — annotate a struct `//+sql:scan` and it emits
  a concrete `scan_<T>` (the postgres driver produces the same `Value` variants
  the scanners expect).
- **schemagen** introspects a live server in DB mode:

  ```sh
  just schema-db-postgres 'postgres://user:pass@localhost:5432/mydb?sslmode=disable' ./myapp
  # → ./myapp/schema.gen.odin: row structs + typed sqlbuilder descriptors
  ```

  It reads `information_schema` (base tables in the `public` schema; views
  skipped), maps each column's `udt_name` to the Odin type the driver scans, and
  marks `Maybe(T)` for nullable columns. Run `scangen` after to get concrete
  scanners for the generated structs.

## TLS

TLS is **opt-in at build time**, so the default build stays pure-Odin with no C
dependency. Build with `-define:DATABASE_PG_TLS=true` (which links OpenSSL —
`libssl`/`libcrypto`) to enable encrypted connections:

```sh
# build the odb CLI with TLS, then introspect a TLS-only server:
just odb-build-tls
bin/odb schema -driver postgres -db 'postgres://user:pass@host:5432/db?sslmode=require' ./myapp
# or directly: just schema-db-postgres-tls 'postgres://...?sslmode=require' ./myapp
```

On macOS the homebrew OpenSSL lib path is added automatically; override it with
`OPENSSL_LIB_DIR=...`. To link OpenSSL in your own build, pass the same flags:
`-define:DATABASE_PG_TLS=true -extra-linker-flags:-L/path/to/openssl/lib`.

sslmode handling:

| sslmode | default build | TLS build (`DATABASE_PG_TLS=true`) |
|---|---|---|
| `disable` | plaintext | plaintext |
| `allow` / `prefer` | plaintext | try TLS, fall back to plaintext |
| `require` | error (rebuild with TLS) | **encrypt** (no cert verification) |
| `verify-ca` / `verify-full` | error | not implemented yet — use `require` |

`require` encrypts but does **not** verify the server certificate (matching
libpq's `require`). Certificate/hostname verification (`verify-ca`/`verify-full`)
and client certificates are planned.

## Limitations (v1)

- **TLS** is `require`-level only (see above) — no certificate verification yet.
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

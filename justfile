# odin-databases — common dev tasks.
# Run `just` to see all recipes.
#
# Requires: odin, just, sqlite3 (for DB-mode codegen), and (for bindings regen)
# `bindgen.bin` on PATH (the odin-c-bindgen binary; aliased to `obg` in some shells).

set shell := ["bash", "-cu"]

# The repo is consumed as the `database` collection: import "database:sql", etc.
# Every odin command registers it (rooted at the repo, so no ../.. imports).
coll := "-collection:database=."

# Where `just install` puts the `odb` binary. Defaults to ~/.local/bin (no sudo,
# on PATH for most shells). Override with `ODB_INSTALL_DIR` or `just install <dir>`.
install_dir := env_var_or_default("ODB_INSTALL_DIR", env_var("HOME") / ".local" / "bin")

# Flags that enable the PostgreSQL driver's TLS support (links OpenSSL). The
# default build is plaintext-only and needs no OpenSSL. On macOS we add the
# homebrew openssl lib path; on Linux libssl is usually on the default path.
# Override the lib dir with OPENSSL_LIB_DIR.
openssl_lib_dir := env_var_or_default("OPENSSL_LIB_DIR", if os() == "macos" { "/opt/homebrew/opt/openssl@3/lib" } else { "" })
pg_tls_flags := "-define:DATABASE_PG_TLS=true" + if openssl_lib_dir != "" { " -extra-linker-flags:-L" + openssl_lib_dir } else { "" }

# The DuckDB driver links prebuilt STATIC archives (fetched with `just
# duckdb-lib` into bindings/duckdb/lib/<os>_<arch>/; not checked in). Binaries
# are self-contained — no loader path needed at run time.

# Default: list available recipes.
default:
    @just --list

# Regenerate scan mappers + typed descriptors for a package dir (default: repo root).
gen dir=".": (scan dir) (schema dir)

# Run the demo (regens generated code first).
run: gen
    odin run . {{coll}}

# Build the demo binary (regens generated code first).
build: gen
    odin build . {{coll}} -out:bin/odin-databases

# Type-check without building.
check:
    odin check . {{coll}}

# Type-check every importable package in the repo. Library packages (and the
# test-only `testing` example) get -no-entry-point so the check doesn't fail
# looking for `main`.
check-all:
    odin check . {{coll}}
    odin check sql -no-entry-point {{coll}}
    odin check sql/driver -no-entry-point {{coll}}
    odin check sqlbuilder -no-entry-point {{coll}}
    odin check migrate -no-entry-point {{coll}}
    odin check examples/quickstart {{coll}}
    odin check examples/query_builder {{coll}}
    odin check examples/introspection {{coll}}
    odin check examples/ss {{coll}} -define:DATABASE_PG_TLS=true
    odin check examples/migrations {{coll}}
    odin check examples/duckdb {{coll}}
    odin check examples/testing -no-entry-point {{coll}}
    odin check drivers/sqlite -no-entry-point {{coll}}
    odin check drivers/postgres -no-entry-point {{coll}}
    odin check drivers/postgres -no-entry-point {{coll}} -define:DATABASE_PG_TLS=true
    odin check drivers/duckdb -no-entry-point {{coll}}
    odin check bindings/duckdb/duckdb -no-entry-point {{coll}}
    odin check drivers/mock -no-entry-point {{coll}}
    odin check tools/scangen {{coll}}
    odin check tools/schemagen {{coll}}
    odin check tools/schemagen {{coll}} -define:SCHEMAGEN_DUCKDB=true
    odin check tools/migragen {{coll}}
    odin check tools/migranew {{coll}}
    odin check tools/odb {{coll}}
    odin check tests -no-entry-point {{coll}}

# Run all tests. The postgres suite skips itself unless ODIN_PG_TEST_DSN is set
# (see `just test-postgres`), but is built here so its test code can't bitrot.
test:
    odin test drivers/mock {{coll}}
    odin test drivers/sqlite {{coll}}
    odin test drivers/postgres {{coll}}
    odin test drivers/duckdb {{coll}}
    odin test sqlbuilder {{coll}}
    odin test migrate {{coll}}
    odin test tools/migragen {{coll}}
    odin test tools/migranew {{coll}}
    odin test tests {{coll}}
    odin test examples/testing {{coll}}

# Run tests in a specific package.
test-pkg pkg:
    odin test {{pkg}} {{coll}}

# Run the PostgreSQL driver's integration tests against a live server. The
# tests skip themselves unless ODIN_PG_TEST_DSN is set, so pass a DSN:
#   just test-postgres 'postgres://odin:secret@localhost:55432/odintest?sslmode=disable'
# Spin a throwaway server up first with `just postgres-docker`.
test-postgres dsn:
    ODIN_PG_TEST_DSN='{{dsn}}' odin test drivers/postgres {{coll}}

# Same, but builds with TLS (OpenSSL) so the suite runs over an encrypted
# connection — pass a sslmode=require DSN:
#   just test-postgres-tls 'postgres://odin:secret@localhost:55432/odintest?sslmode=require'
test-postgres-tls dsn:
    ODIN_PG_TEST_DSN='{{dsn}}' odin test drivers/postgres {{coll}} {{pg_tls_flags}}

# Start a throwaway PostgreSQL 17 container for `just test-postgres`
# (user=odin, password=secret, db=odintest, host port 55432). Requires Docker.
postgres-docker:
    docker rm -f odin-pg-test >/dev/null 2>&1 || true
    docker run -d --name odin-pg-test \
        -e POSTGRES_PASSWORD=secret -e POSTGRES_USER=odin -e POSTGRES_DB=odintest \
        -p 55432:5432 postgres:17
    @echo "Waiting for readiness..."
    until docker exec odin-pg-test pg_isready -U odin -d odintest >/dev/null 2>&1; do sleep 1; done
    @echo "Ready. DSN: postgres://odin:secret@localhost:55432/odintest?sslmode=disable"

# Stop and remove the throwaway PostgreSQL container.
postgres-docker-stop:
    docker rm -f odin-pg-test >/dev/null 2>&1 || true

# --- Examples -----------------------------------------------------------------

# Run an example by name, e.g. `just run-example quickstart`.
run-example name:
    odin run examples/{{name}} {{coll}}

# Run an example's tests by name, e.g. `just test-example testing`.
test-example name:
    odin test examples/{{name}} {{coll}}

# Smoke-test the generated `ss` postgres schema with a typed query-builder
# SELECT. Reads connection settings from examples/ss/.env (copy the .env.example
# first). Built with the TLS define so sslmode=require DSNs work too.
run-ss:
    mkdir -p bin
    odin run examples/ss {{coll}} {{pg_tls_flags}} -out:bin/ss

# --- Code generation ----------------------------------------------------------

# Unified codegen CLI: dispatches to every generator as a subcommand, e.g.
#   just odb scan ./pkg
#   just odb schema -db=app.db ./pkg
#   just odb migrate-gen ./migrations ./pkg
#   just odb <cmd> -h        # flags for a subcommand
odb *args:
    odin run tools/odb {{coll}} -- {{args}}

# Build the unified `odb` CLI to bin/odb (so it can be run without `odin run`).
odb-build:
    mkdir -p bin
    odin build tools/odb {{coll}} -out:bin/odb

# Build `odb` with PostgreSQL TLS support (links OpenSSL) to bin/odb, so
# `bin/odb schema -driver postgres -db '...sslmode=require'` can connect over TLS.
odb-build-tls:
    mkdir -p bin
    odin build tools/odb {{coll}} {{pg_tls_flags}} -out:bin/odb

# Build a release `odb` and install it onto your PATH.
#   just install                 # → ~/.local/bin/odb  (or $ODB_INSTALL_DIR)
#   just install /usr/local/bin  # explicit dir (may need: sudo just install ...)
install dir=install_dir:
    mkdir -p "{{dir}}"
    odin build tools/odb {{coll}} -out:"{{dir}}/odb" -o:speed
    @echo "installed odb -> {{dir}}/odb"
    @case ":$PATH:" in \
        *":{{dir}}:"*) ;; \
        *) echo "note: {{dir}} is not on your PATH — add it, e.g. 'export PATH=\"{{dir}}:\$PATH\"'" ;; \
    esac

# Remove an installed odb (mirror of `just install`).
uninstall dir=install_dir:
    rm -f "{{dir}}/odb"
    @echo "removed {{dir}}/odb"

# Run scangen on a package directory (default: repo root).
# Generates `<dir>/scan.gen.odin` for any struct tagged `//+sql:scan`.
scan dir=".":
    odin run tools/scangen {{coll}} -- {{dir}}

# Run schemagen on a package directory (default: repo root).
# Generates `<dir>/schema.gen.odin` typed descriptors for any struct tagged
# `//+sql:table <name>`.
schema dir=".":
    odin run tools/schemagen {{coll}} -- {{dir}}

# Run schemagen's DB front-end: introspect <db> and write row structs +
# typed descriptors to <dir>/schema.gen.odin (the database is the source of
# truth — structs are emitted too).
schema-db db dir:
    odin run tools/schemagen {{coll}} -- -db={{db}} {{dir}}

# Run schemagen's PostgreSQL DB front-end: introspect a live server (via
# information_schema) and write row structs + typed descriptors. <dsn> is a
# postgres:// URL or keyword DSN, e.g.
#   just schema-db-postgres 'postgres://odin:secret@localhost:55432/odintest?sslmode=disable' ./myapp
schema-db-postgres dsn dir:
    odin run tools/schemagen {{coll}} -- -driver=postgres -db={{dsn}} {{dir}}

# Same, but over a TLS connection (sslmode=require). Builds the postgres driver
# with OpenSSL. Use when your server only accepts encrypted connections.
schema-db-postgres-tls dsn dir:
    odin run tools/schemagen {{coll}} {{pg_tls_flags}} -- -driver=postgres -db={{dsn}} {{dir}}

# Run schemagen's DuckDB DB front-end: introspect <db> (a DuckDB file, via
# information_schema) and write row structs + typed descriptors. DuckDB
# introspection is opt-in (links libduckdb), so this builds with
# -define:SCHEMAGEN_DUCKDB=true. Run `just duckdb-lib` first if the static
# archives aren't present. Composite columns (LIST/STRUCT/...) are
# skipped with a warning.
#   just schema-db-duckdb app.duckdb ./myapp
schema-db-duckdb db dir:
    odin run tools/schemagen {{coll}} -define:SCHEMAGEN_DUCKDB=true -- -driver=duckdb -db={{db}} {{dir}}

# Scaffold a new, empty migration pair (<version>_<name>.up.sql / .down.sql)
# into <dir>, using a fresh YYYYMMDDHHMMSS timestamp.
#   just migrate-new migrations "create users"
migrate-new dir name:
    odin run tools/migranew {{coll}} -- {{dir}} "{{name}}"

# Run migragen: embed a directory of .sql migrations into <out-dir>/migrations.gen.odin.
#   just gen-migrations <sql-dir> <out-dir>
gen-migrations sqldir outdir:
    odin run tools/migragen {{coll}} -- {{sqldir}} {{outdir}}

# Regenerate the migrations example's embedded migrations.gen.odin.
gen-migrations-example: (gen-migrations "examples/migrations/migrations" "examples/migrations")

# Regenerate the query_builder example (struct mode: scangen + schemagen).
gen-query-builder: (gen "examples/query_builder")

# Regenerate the introspection example from its schema.sql by materializing a
# throwaway SQLite DB and running schemagen's DB front-end, then scangen so the
# generated `//+sql:scan` structs get concrete scanners. Requires `sqlite3`.
gen-introspection:
    #!/usr/bin/env bash
    set -euo pipefail
    db="$(mktemp -u -t schemagen.XXXXXX.db)"
    sqlite3 "$db" < examples/introspection/schema.sql
    odin run tools/schemagen {{coll}} -- -db="$db" examples/introspection
    odin run tools/scangen {{coll}} -- examples/introspection
    rm -f "$db"

# Regenerate every generated file in the repo.
gen-all: gen gen-query-builder gen-introspection gen-migrations-example

# Show what scangen would touch without writing anything (useful for CI guards).
scan-check dir=".":
    @echo "Annotated structs under {{dir}}:"
    @grep -rn '//+sql:scan' --include='*.odin' {{dir}} || echo "  (none)"

# --- SQLite bindings ----------------------------------------------------------

# Regenerate Odin bindings from sqlite3.h via odin-c-bindgen.
gen-bindings:
    bindgen.bin bindings/sqlite

# Build the static SQLite lib for the current host into bindings/sqlite/lib/<os>_<arch>/.
sqlite-lib:
    bindings/sqlite/build_libs.sh

# Run the raw-bindings smoke test (verifies the static lib + bindings link).
bindings-example:
    cd bindings/sqlite/example && odin run .

# --- DuckDB bindings + driver -------------------------------------------------

# Fetch the prebuilt DuckDB static archives for this host into
# bindings/duckdb/lib/<os>_<arch>/ (not checked in; ~100MB). They come from
# github.com/duckdb/duckdb-go-bindings — pin one of its tags with e.g.
# `just duckdb-lib v0.10503.0` (= DuckDB v1.5.3; see their README mapping).
duckdb-lib version="":
    bash bindings/duckdb/fetch_libs.sh {{version}}

# Regenerate Odin bindings from bindings/duckdb/input/duckdb.h via odin-c-bindgen
# (same `bindgen.bin`/`obg` tool the SQLite bindings use). The wrapper script
# feeds libclang the host's C-stdlib/builtin include paths — without them the
# regenerate silently produces broken (all-i32) types. See the script header
# and bindings/duckdb/README.md. NOTE: the bindings are committed; you only need
# this when updating input/duckdb.h.
gen-duckdb-bindings:
    bash bindings/duckdb/gen_bindings.sh

# Run the DuckDB driver's test suite (links the prebuilt static archives).
# Run `just duckdb-lib` first if they aren't present.
test-duckdb:
    odin test drivers/duckdb {{coll}}

# Run the raw DuckDB bindings smoke test (verifies the static archives + bindings link).
duckdb-bindings-example:
    cd bindings/duckdb/example && odin run .

# Run the DuckDB driver example.
#   just duckdb-lib && just run-duckdb-example
run-duckdb-example:
    mkdir -p bin
    odin run examples/duckdb {{coll}} -out:bin/duckdb-example

# Run the DuckDB introspection example.
#   just duckdb-lib && just run-duckdb-introspection-example
run-duckdb-introspection-example:
    mkdir -p bin
    odin run examples/duckdb-introspection {{coll}} -out:bin/duckdb-introspection-example

# --- Maintenance --------------------------------------------------------------

# Remove generated source and local build artifacts.
clean:
    find . -name 'scan.gen.odin' -not -path './.git/*' -delete
    find . -name 'schema.gen.odin' -not -path './.git/*' -delete
    rm -rf bin
    rm -f main bindings/sqlite/example/example bindings/sqlite/example/main

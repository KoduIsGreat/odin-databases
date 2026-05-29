# odin-databases — common dev tasks.
# Run `just` to see all recipes.
#
# Requires: odin, just, sqlite3 (for DB-mode codegen), and (for bindings regen)
# `bindgen.bin` on PATH (the odin-c-bindgen binary; aliased to `obg` in some shells).

set shell := ["bash", "-cu"]

# Default: list available recipes.
default:
    @just --list

# Regenerate scan mappers + typed descriptors for a package dir (default: repo root).
gen dir=".": (scan dir) (schema dir)

# Run the demo (regens generated code first).
run: gen
    odin run .

# Build the demo binary (regens generated code first).
build: gen
    odin build . -out:bin/odin-databases

# Type-check without building.
check:
    odin check .

# Type-check every importable package in the repo. Library packages (and the
# test-only `testing` example) get -no-entry-point so the check doesn't fail
# looking for `main`.
check-all:
    odin check .
    odin check database/sql -no-entry-point
    odin check database/sqlbuilder -no-entry-point
    odin check examples/quickstart
    odin check examples/query_builder
    odin check examples/introspection
    odin check examples/testing -no-entry-point
    odin check drivers/sqlite -no-entry-point
    odin check drivers/mock -no-entry-point
    odin check tools/scangen
    odin check tools/schemagen
    odin check tests -no-entry-point

# Run all tests.
test:
    odin test drivers/mock
    odin test drivers/sqlite
    odin test database/sqlbuilder
    odin test tests
    odin test examples/testing

# Run tests in a specific package.
test-pkg pkg:
    odin test {{pkg}}

# --- Examples -----------------------------------------------------------------

# Run an example by name, e.g. `just run-example quickstart`.
run-example name:
    odin run examples/{{name}}

# Run an example's tests by name, e.g. `just test-example testing`.
test-example name:
    odin test examples/{{name}}

# --- Code generation ----------------------------------------------------------

# Run scangen on a package directory (default: repo root).
# Generates `<dir>/scan.gen.odin` for any struct tagged `//+sql:scan`.
scan dir=".":
    odin run tools/scangen -- {{dir}}

# Run schemagen on a package directory (default: repo root).
# Generates `<dir>/schema.gen.odin` typed descriptors for any struct tagged
# `//+sql:table <name>`.
schema dir=".":
    odin run tools/schemagen -- {{dir}}

# Run schemagen's DB front-end: introspect <db> and write row structs +
# typed descriptors to <dir>/schema.gen.odin (the database is the source of
# truth — structs are emitted too).
schema-db db dir:
    odin run tools/schemagen -- -db={{db}} {{dir}}

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
    odin run tools/schemagen -- -db="$db" examples/introspection
    odin run tools/scangen -- examples/introspection
    rm -f "$db"

# Regenerate every generated file in the repo.
gen-all: gen gen-query-builder gen-introspection

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

# --- Maintenance --------------------------------------------------------------

# Remove generated source and local build artifacts.
clean:
    find . -name 'scan.gen.odin' -not -path './.git/*' -delete
    find . -name 'schema.gen.odin' -not -path './.git/*' -delete
    rm -rf bin
    rm -f main bindings/sqlite/example/example bindings/sqlite/example/main

# odin-databases — common dev tasks.
# Run `just` to see all recipes.
#
# Requires: odin, just, and (for bindings regen) `bindgen.bin` on PATH
# (the odin-c-bindgen binary; aliased to `obg` in some shells).

set shell := ["bash", "-cu"]

# Default: list available recipes.
default:
    @just --list

# Run the demo (regens scan code first).
run: scan
    odin run .

# Build the demo binary (regens scan code first).
build: scan
    odin build . -out:bin/odin-databases

# Type-check without building.
check:
    odin check .

# Run all tests.
test:
    odin test drivers/mock

# Run tests in a specific package.
test-pkg pkg:
    odin test {{pkg}}

# --- Code generation ----------------------------------------------------------

# Run scangen on a single package directory (default: repo root).
# Generates `<dir>/scan.gen.odin` for any struct tagged `//+sql:scan`.
scan dir=".":
    odin run tools/scangen -- {{dir}}

# Run scangen on every package in the repo that has `//+sql:scan` annotations.
# Add new dirs here as the project grows.
scan-all:
    just scan .
    # just scan path/to/other/pkg

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
    rm -rf bin
    rm -f main bindings/sqlite/example/example bindings/sqlite/example/main

# Show what scangen would touch without writing anything (useful for CI guards).
scan-check dir=".":
    @echo "Annotated structs under {{dir}}:"
    @grep -rn '//+sql:scan' --include='*.odin' {{dir}} || echo "  (none)"

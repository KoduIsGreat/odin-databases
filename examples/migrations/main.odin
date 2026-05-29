// migrations — schema migrations with the `database:migrate` runner.
//
// Loads .sql files from ./migrations via migrate.from_dir, applies them to a
// SQLite database, prints the status table, then rolls the most recent
// migration back and prints the status again.
//
// Run: just run-example migrations   (run from the repo root, so the relative
// MIGRATIONS_DIR path resolves)
package migrations_example

import "core:fmt"

import sql "database:sql"
import migrate "database:migrate"
import sqlite "database:drivers/sqlite"

MIGRATIONS_DIR :: "examples/migrations/migrations"

main :: proc() {
	db, open_err := sql.open(&sqlite.driver, ":memory:")
	if open_err != nil {
		fmt.eprintfln("open: %v", open_err)
		return
	}
	defer sql.close(db)

	// Load the migration set from disk (paired <version>_<name>.up/.down.sql).
	ms, lerr := migrate.from_dir(MIGRATIONS_DIR)
	if lerr != nil {
		fmt.eprintfln("load: %v", lerr)
		return
	}
	defer migrate.destroy_migrations(ms)

	// Apply everything pending. Idempotent: safe to run on every startup.
	applied, uerr := migrate.up(db, ms)
	if uerr != nil {
		fmt.eprintfln("up: %v", uerr)
		return
	}
	fmt.printfln("applied %d migration(s)", applied)
	print_status(db, ms)

	// Roll the most recent migration back one step.
	if derr := migrate.down(db, ms); derr != nil {
		fmt.eprintfln("down: %v", derr)
		return
	}
	fmt.println("\nrolled back the latest migration")
	print_status(db, ms)
}

print_status :: proc(db: ^sql.DB, ms: []migrate.Migration) {
	st, serr := migrate.status(db, ms)
	if serr != nil {
		fmt.eprintfln("status: %v", serr)
		return
	}
	defer migrate.destroy_statuses(st)

	fmt.println("  version         name              applied")
	for s in st {
		mark := "yes" if s.applied else "no"
		fmt.printfln("  %-15d %-17s %s", s.version, s.name, mark)
	}
}

package sqlite

import "core:testing"

import sql "database:sql"

// Verifies the loadable-extension API is wired through to SQLite's C loader.
// (We can't load a real extension here, so we assert the enable call succeeds
// and a missing-path load returns an error rather than crashing.)
@(test)
test_load_extension_wiring :: proc(t: ^testing.T) {
	db, err := sql.open(&driver, ":memory:")
	testing.expect_value(t, err, nil)
	defer sql.close(db)

	conn, cerr := sql.checkout(db)
	testing.expect_value(t, cerr, nil)
	defer sql.checkin(&conn)

	testing.expect_value(t, enable_load_extension(&conn, true), nil)

	lerr := load_extension(&conn, "/no/such/extension/path")
	testing.expect(t, lerr != nil, "expected an error loading a missing extension")
}

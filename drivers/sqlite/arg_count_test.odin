package sqlite

import "core:testing"

import sql "database:sql"

// Argument count must be validated against the query's placeholders. SQLite
// would otherwise raise a cryptic range error when over-supplied, or — worse —
// silently bind NULL for missing arguments when under-supplied.
@(test)
test_arg_count_mismatch :: proc(t: ^testing.T) {
	db, err := sql.open(&driver, ":memory:")
	testing.expect_value(t, err, nil)
	defer sql.close(db)

	_, ce := sql.exec(db, "CREATE TABLE t (id INTEGER, name TEXT)")
	testing.expect_value(t, ce, nil)

	expect_wrong_count :: proc(t: ^testing.T, e: sql.Error, expected, got: int) {
		ae, ok := e.(sql.Arg_Error)
		testing.expect(t, ok, "expected an Arg_Error")
		testing.expect_value(t, ae.kind, sql.Arg_Error_Kind.Wrong_Count)
		testing.expect_value(t, ae.args_expected, expected)
		testing.expect_value(t, ae.args_got, got)
	}

	// Over-supply on a query with no placeholders (the err_handling example bug).
	_, e1 := sql.query(db, "SELECT id FROM t WHERE id > 0", i64(18))
	expect_wrong_count(t, e1, 0, 1)

	// Under-supply: one placeholder, no arguments (pre-fix this silently bound NULL).
	_, e2 := sql.query(db, "SELECT id FROM t WHERE id > ?")
	expect_wrong_count(t, e2, 1, 0)

	// Over-supply on exec.
	_, e3 := sql.exec(db, "INSERT INTO t (id) VALUES (?)", i64(1), i64(2))
	expect_wrong_count(t, e3, 1, 2)

	// Parameterized exec with no args hits the DDL/multi-statement path, which
	// must reject it rather than insert a row of NULLs.
	_, e4 := sql.exec(db, "INSERT INTO t (id, name) VALUES (?, ?)")
	expect_wrong_count(t, e4, 2, 0)

	// The correct count still succeeds.
	_, e5 := sql.exec(db, "INSERT INTO t (id, name) VALUES (?, ?)", i64(1), "ok")
	testing.expect_value(t, e5, nil)
}

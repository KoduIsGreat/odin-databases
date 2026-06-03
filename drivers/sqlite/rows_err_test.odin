package sqlite

import "core:testing"

import sql "database:sql"

// A query that yields rows and then fails mid-stream must surface the error via
// rows_err — not masquerade as a clean end-of-rows. Here the first row returns
// 1, and the second evaluates abs(-9223372036854775808), which SQLite rejects
// with an integer-overflow error: step() returns an error code (not DONE), so
// next() returns false with rows_err set.
@(test)
test_rows_err_mid_stream :: proc(t: ^testing.T) {
	db, err := sql.open(&driver, ":memory:")
	testing.expect_value(t, err, nil)
	defer sql.close(db)

	rows, qerr := sql.query(db, "SELECT 1 UNION ALL SELECT abs(-9223372036854775808)")
	testing.expect_value(t, qerr, nil)
	defer sql.close_rows(&rows)

	n := 0
	for sql.next(&rows) {
		v: i64
		testing.expect_value(t, sql.scan(&rows, &v), nil)
		n += 1
	}

	// Exactly one row materialized before the error stopped iteration.
	testing.expect_value(t, n, 1)
	// The loop ended because of an error, not clean EOF.
	testing.expect(t, sql.rows_err(&rows) != nil, "expected a mid-stream iteration error")
}

// The negative control: a result that drains fully must leave rows_err nil, so
// callers can trust nil to mean "fully consumed".
@(test)
test_rows_err_nil_on_clean_eof :: proc(t: ^testing.T) {
	db, err := sql.open(&driver, ":memory:")
	testing.expect_value(t, err, nil)
	defer sql.close(db)

	rows, qerr := sql.query(db, "SELECT 1 UNION ALL SELECT 2")
	testing.expect_value(t, qerr, nil)
	defer sql.close_rows(&rows)

	n := 0
	for sql.next(&rows) {
		v: i64
		testing.expect_value(t, sql.scan(&rows, &v), nil)
		n += 1
	}
	testing.expect_value(t, n, 2)
	testing.expect_value(t, sql.rows_err(&rows), nil)
}

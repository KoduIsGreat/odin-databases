package sqlite

import "core:testing"

import sql "database:sql"

// A parameterless exec must run every ';'-separated statement, not just the
// first (prepare_v2 only compiles one at a time). Migration / DDL scripts rely
// on this.
@(test)
test_exec_runs_multiple_statements :: proc(t: ^testing.T) {
	db, err := sql.open(&driver, ":memory:")
	testing.expect_value(t, err, nil)
	defer sql.close(db)

	_, e := sql.exec(
		db,
		"CREATE TABLE a (id INTEGER);\n" +
		"CREATE TABLE b (id INTEGER);\n" +
		"INSERT INTO a (id) VALUES (1);",
	)
	testing.expect_value(t, e, nil)

	count_rows :: proc(db: ^sql.DB, table: string) -> i64 {
		row := sql.query_row(
			db,
			"SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?",
			table,
		)
		defer sql.close_row(&row)
		n: i64
		sql.scan(&row, &n)
		return n
	}

	testing.expect(t, count_rows(db, "a") == 1, "table a should exist")
	testing.expect(t, count_rows(db, "b") == 1, "table b should exist")

	// Trailing comment after the final statement must not error.
	_, e2 := sql.exec(db, "INSERT INTO a (id) VALUES (2); -- trailing comment\n")
	testing.expect_value(t, e2, nil)

	row := sql.query_row(db, "SELECT count(*) FROM a")
	defer sql.close_row(&row)
	n: i64
	testing.expect_value(t, sql.scan(&row, &n), nil)
	testing.expect_value(t, n, 2)
}

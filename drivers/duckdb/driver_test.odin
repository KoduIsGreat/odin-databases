package duckdb

import "core:testing"
import "core:time"

import sql "database:sql"

// These tests run against an in-memory DuckDB. They pin the pool to a single
// connection so the `:memory:` database is shared across every checkout (each
// pooled connection otherwise gets its own isolated in-memory database).
@(private = "file")
open_mem :: proc(t: ^testing.T) -> ^sql.DB {
	db, err := sql.open(&driver, ":memory:")
	testing.expect_value(t, err, nil)
	sql.set_max_open_conns(db, 1)
	return db
}

@(test)
test_exec_and_query :: proc(t: ^testing.T) {
	db := open_mem(t)
	defer sql.close(db)

	_, e := sql.exec(db, "CREATE TABLE users (id INTEGER, name VARCHAR, age INTEGER)")
	testing.expect_value(t, e, nil)

	res, ie := sql.exec(db, "INSERT INTO users VALUES (?, ?, ?)", i64(1), "Alice", i64(30))
	testing.expect_value(t, ie, nil)
	testing.expect_value(t, res.rows_affected, 1)

	sql.exec(db, "INSERT INTO users VALUES (?, ?, ?)", i64(2), "Bob", i64(17))

	rows, qe := sql.query(db, "SELECT id, name, age FROM users WHERE age >= ? ORDER BY id", i64(18))
	testing.expect_value(t, qe, nil)
	defer sql.rows_close(&rows)

	count := 0
	for sql.next(&rows) {
		id, age: i64
		nm: string
		testing.expect_value(t, sql.scan(&rows, &id, &nm, &age), nil)
		defer delete(nm) // scan clones strings into caller-owned memory
		testing.expect_value(t, id, 1)
		testing.expect_value(t, nm, "Alice")
		testing.expect_value(t, age, 30)
		count += 1
	}
	testing.expect_value(t, sql.rows_err(&rows), nil)
	testing.expect_value(t, count, 1)
}

// A parameterless exec must run every ';'-separated statement (DDL scripts).
@(test)
test_exec_multiple_statements :: proc(t: ^testing.T) {
	db := open_mem(t)
	defer sql.close(db)

	_, e := sql.exec(
		db,
		"CREATE TABLE a (id INTEGER);\n" +
		"CREATE TABLE b (id INTEGER);\n" +
		"INSERT INTO a VALUES (1);",
	)
	testing.expect_value(t, e, nil)

	count_table :: proc(t: ^testing.T, db: ^sql.DB, name: string) -> i64 {
		row := sql.query_row(
			db,
			"SELECT count(*) FROM information_schema.tables WHERE table_name = ?",
			name,
		)
		defer sql.close_row(&row)
		n: i64
		sql.scan(&row, &n)
		return n
	}

	testing.expect(t, count_table(t, db, "a") == 1, "table a should exist")
	testing.expect(t, count_table(t, db, "b") == 1, "table b should exist")
}

@(test)
test_prepared_statement :: proc(t: ^testing.T) {
	db := open_mem(t)
	defer sql.close(db)

	// Prepared statements are tied to a connection, so run the whole test on one
	// explicitly checked-out Conn.
	conn, ce := sql.checkout(db)
	testing.expect_value(t, ce, nil)
	defer sql.checkin(&conn)

	sql.exec(&conn, "CREATE TABLE t (n INTEGER)")

	stmt, pe := sql.prepare(&conn, "INSERT INTO t VALUES (?)")
	testing.expect_value(t, pe, nil)

	for i in 1 ..= 3 {
		_, se := sql.stmt_exec(&stmt, []sql.Value{i64(i)})
		testing.expect_value(t, se, nil)
	}
	sql.stmt_close(&stmt)

	row := sql.query_row(&conn, "SELECT sum(n) FROM t")
	defer sql.close_row(&row)
	sum: i64
	testing.expect_value(t, sql.scan(&row, &sum), nil)
	testing.expect_value(t, sum, 6)
}

@(test)
test_types_roundtrip :: proc(t: ^testing.T) {
	db := open_mem(t)
	defer sql.close(db)

	sql.exec(db, "CREATE TABLE v (b BOOLEAN, i BIGINT, f DOUBLE, s VARCHAR, blob BLOB)")
	args := []sql.Value{true, i64(-42), f64(3.5), "hello", []byte{0x01, 0x02, 0x03}}
	_, e := sql.exec(db, "INSERT INTO v VALUES (?, ?, ?, ?, ?)", ..args)
	testing.expect_value(t, e, nil)

	row := sql.query_row(db, "SELECT b, i, f, s, blob FROM v")
	defer sql.close_row(&row)

	b: bool
	i: i64
	f: f64
	s: string
	blob: []byte
	testing.expect_value(t, sql.scan(&row, &b, &i, &f, &s, &blob), nil)
	defer delete(s) // scan clones string/[]byte into caller-owned memory
	defer delete(blob)
	testing.expect_value(t, b, true)
	testing.expect_value(t, i, -42)
	testing.expect_value(t, f, 3.5)
	testing.expect_value(t, s, "hello")
	testing.expect_value(t, len(blob), 3)
	testing.expect_value(t, blob[0], 0x01)
	testing.expect_value(t, blob[2], 0x03)
}

@(test)
test_null_value :: proc(t: ^testing.T) {
	db := open_mem(t)
	defer sql.close(db)

	row := sql.query_row(db, "SELECT NULL::INTEGER, 5::INTEGER")
	defer sql.close_row(&row)

	a: Maybe(i64)
	b: i64
	testing.expect_value(t, sql.scan(&row, &a, &b), nil)
	_, has := a.?
	testing.expect(t, !has, "first column should scan as nil Maybe")
	testing.expect_value(t, b, 5)
}

@(test)
test_timestamp_roundtrip :: proc(t: ^testing.T) {
	db := open_mem(t)
	defer sql.close(db)

	sql.exec(db, "CREATE TABLE ts (at TIMESTAMP)")
	want := time.Time{_nsec = 1_700_000_000 * i64(1e9)}
	_, e := sql.exec(db, "INSERT INTO ts VALUES (?)", want)
	testing.expect_value(t, e, nil)

	// Scan into a struct so the column maps to the `at` field by name. (Scanning
	// a lone `time.Time` would hit scan's reflective struct path, since a
	// time.Time is itself a struct — that's a property of the sql layer, not the
	// driver.)
	Row_TS :: struct {
		at: time.Time,
	}
	row := sql.query_row(db, "SELECT at FROM ts")
	defer sql.close_row(&row)
	got: Row_TS
	testing.expect_value(t, sql.scan(&row, &got), nil)
	// DuckDB TIMESTAMP has microsecond resolution; compare at that granularity.
	testing.expect_value(t, got.at._nsec / 1000, want._nsec / 1000)
}

@(test)
test_transaction_commit_rollback :: proc(t: ^testing.T) {
	db := open_mem(t)
	defer sql.close(db)

	sql.exec(db, "CREATE TABLE acct (n INTEGER)")

	// Rolled-back work must not persist.
	tx, be := sql.begin(db)
	testing.expect_value(t, be, nil)
	sql.exec(&tx, "INSERT INTO acct VALUES (1)")
	testing.expect_value(t, sql.rollback(&tx), nil)

	// Committed work must persist.
	tx2, _ := sql.begin(db)
	sql.exec(&tx2, "INSERT INTO acct VALUES (2)")
	testing.expect_value(t, sql.commit(&tx2), nil)

	row := sql.query_row(db, "SELECT count(*) FROM acct")
	defer sql.close_row(&row)
	n: i64
	sql.scan(&row, &n)
	testing.expect_value(t, n, 1)
}

@(test)
test_query_error :: proc(t: ^testing.T) {
	db := open_mem(t)
	defer sql.close(db)

	_, e := sql.exec(db, "SELECT * FROM nonexistent_table")
	testing.expect(t, e != nil, "querying a missing table should error")

	// The message is cloned out of the (now-destroyed) DuckDB result, so it must
	// still be readable here rather than dangling into freed memory.
	de, ok := e.(sql.Driver_Error)
	testing.expect(t, ok, "expected a Driver_Error")
	testing.expect(t, len(de.message) > 0, "error message should be populated")
}

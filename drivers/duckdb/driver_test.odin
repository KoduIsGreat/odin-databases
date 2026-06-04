package duckdb

import "core:fmt"
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

// Wide integers must round-trip without precision loss: HUGEINT (i128),
// UBIGINT (u64, exceeds i64), and UHUGEINT (u128, exceeds i128).
@(test)
test_wide_integers :: proc(t: ^testing.T) {
	db := open_mem(t)
	defer sql.close(db)

	// Cast from string literals: a bare 128-bit numeric literal is parsed as
	// DOUBLE first (losing precision / overflowing), so go through VARCHAR.
	row := sql.query_row(
		db,
		"SELECT '170141183460469231731687303715884105727'::HUGEINT, " +
		"'18446744073709551615'::UBIGINT, " +
		"'340282366920938463463374607431768211455'::UHUGEINT",
	)
	defer sql.close_row(&row)

	h, ub: i128
	uh: u128
	testing.expect_value(t, sql.scan(&row, &h, &ub, &uh), nil)
	testing.expect_value(t, h, i128(170141183460469231731687303715884105727))
	testing.expect_value(t, ub, i128(18446744073709551615))
	testing.expect_value(t, uh, u128(340282366920938463463374607431768211455))
}

// A DECIMAL with more significant digits than f64 can hold must scan exactly
// when read into a string (the lossless path).
@(test)
test_decimal_exact :: proc(t: ^testing.T) {
	db := open_mem(t)
	defer sql.close(db)

	row := sql.query_row(db, "SELECT 12345678901234567890123.4567::DECIMAL(38,4)")
	defer sql.close_row(&row)
	s: string
	testing.expect_value(t, sql.scan(&row, &s), nil)
	defer delete(s)
	testing.expect_value(t, s, "12345678901234567890123.4567")
}

// Exact decimal formatting across sign, leading-zero, and scale-0 cases.
@(test)
test_decimal_formatting :: proc(t: ^testing.T) {
	db := open_mem(t)
	defer sql.close(db)

	Case :: struct {
		expr: string,
		want: string,
	}
	cases := []Case {
		{"0.0005::DECIMAL(10,4)", "0.0005"},
		{"-12.3400::DECIMAL(10,4)", "-12.3400"},
		{"42::DECIMAL(10,0)", "42"},
	}
	for c in cases {
		row := sql.query_row(db, fmt.tprintf("SELECT %s", c.expr))
		s: string
		testing.expect_value(t, sql.scan(&row, &s), nil)
		testing.expect(t, s == c.want, fmt.tprintf("decimal %s -> %q, want %q", c.expr, s, c.want))
		delete(s)
		sql.close_row(&row)
	}
}

// Scanning a DECIMAL into f64 is the convenient (lossy-by-choice) path.
@(test)
test_decimal_as_f64 :: proc(t: ^testing.T) {
	db := open_mem(t)
	defer sql.close(db)

	row := sql.query_row(db, "SELECT 3.14::DECIMAL(10,2)")
	defer sql.close_row(&row)
	f: f64
	testing.expect_value(t, sql.scan(&row, &f), nil)
	testing.expect(t, abs(f - 3.14) < 1e-9, fmt.tprintf("decimal as f64 -> %v, want ~3.14", f))
}

// Every TIMESTAMP scale (s/ms/ns) and TIMESTAMPTZ must decode to the same
// instant — the old reader read them all as microseconds, corrupting s/ms/ns.
@(test)
test_timestamp_scales :: proc(t: ^testing.T) {
	db := open_mem(t)
	defer sql.close(db)

	Row :: struct {
		s, ms, ns, tz: time.Time,
	}
	row := sql.query_row(
		db,
		"SELECT '2023-11-14 22:13:20'::TIMESTAMP_S AS s, " +
		"'2023-11-14 22:13:20'::TIMESTAMP_MS AS ms, " +
		"'2023-11-14 22:13:20'::TIMESTAMP_NS AS ns, " +
		"'2023-11-14 22:13:20+00'::TIMESTAMPTZ AS tz",
	)
	defer sql.close_row(&row)
	got: Row
	testing.expect_value(t, sql.scan(&row, &got), nil)
	want := i64(1_700_000_000) * i64(1e9) // 2023-11-14 22:13:20 UTC
	testing.expect_value(t, got.s._nsec, want)
	testing.expect_value(t, got.ms._nsec, want)
	testing.expect_value(t, got.ns._nsec, want)
	testing.expect_value(t, got.tz._nsec, want)
}

// TIME_TZ must fold its zone offset into the UTC instant (the old reader
// dropped the offset). 12:30:00+02 == 10:30:00 UTC.
@(test)
test_time_tz :: proc(t: ^testing.T) {
	db := open_mem(t)
	defer sql.close(db)

	Row :: struct {
		t: time.Time,
	}
	row := sql.query_row(db, "SELECT '12:30:00+02'::TIMETZ AS t")
	defer sql.close_row(&row)
	got: Row
	testing.expect_value(t, sql.scan(&row, &got), nil)
	testing.expect_value(t, got.t._nsec, i64(10 * 3600 + 30 * 60) * i64(1e9))
}

// More rows than DuckDB's vector size (2048) forces multiple chunks, exercising
// the chunk-boundary advance and that borrowed VARCHAR cells survive being
// cloned by scan() right up to the boundary.
@(test)
test_multi_chunk :: proc(t: ^testing.T) {
	db := open_mem(t)
	defer sql.close(db)

	rows, e := sql.query(
		db,
		"SELECT i, ('row' || i::VARCHAR) AS s FROM range(5000) t(i) ORDER BY i",
	)
	testing.expect_value(t, e, nil)
	defer sql.rows_close(&rows)

	count := 0
	sum: i128
	for sql.next(&rows) {
		id: i64
		s: string
		testing.expect_value(t, sql.scan(&rows, &id, &s), nil)
		if id == 4999 {testing.expect_value(t, s, "row4999")}
		delete(s)
		sum += i128(id)
		count += 1
	}
	testing.expect_value(t, sql.rows_err(&rows), nil)
	testing.expect_value(t, count, 5000)
	testing.expect_value(t, sum, i128(4999) * 5000 / 2)
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

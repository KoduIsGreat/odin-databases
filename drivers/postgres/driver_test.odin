package postgres

import "core:log"
import "core:os"
import "core:testing"

import sql "database:sql"

// These tests talk to a real PostgreSQL server. They are skipped unless the
// ODIN_PG_TEST_DSN environment variable points at one, e.g.:
//
//   docker run -d --name pg -e POSTGRES_PASSWORD=secret -e POSTGRES_USER=odin \
//       -e POSTGRES_DB=odintest -p 55432:5432 postgres:17
//   ODIN_PG_TEST_DSN='postgres://odin:secret@localhost:55432/odintest?sslmode=disable' \
//       just test-postgres
//
// (See `just test-postgres` / the package README.)

@(private = "file")
test_dsn :: proc() -> (string, bool) {
	dsn, found := os.lookup_env("ODIN_PG_TEST_DSN", context.temp_allocator)
	if !found || dsn == "" {
		log.info("ODIN_PG_TEST_DSN not set — skipping postgres integration test")
		return "", false
	}
	return dsn, true
}

Row :: struct {
	id:     i64,
	label:  string,
	weight: f64,
	ok:     bool,
}

@(test)
test_connect_and_roundtrip :: proc(t: ^testing.T) {
	dsn, ok := test_dsn()
	if !ok {return}

	db, err := sql.open(&driver, dsn)
	testing.expect_value(t, err, nil)
	if err != nil {return}
	defer sql.close(db)

	testing.expect_value(t, sql.ping(db), nil)

	_, err = sql.exec(db, "DROP TABLE IF EXISTS odin_pg_test")
	testing.expect_value(t, err, nil)
	_, err = sql.exec(
		db,
		"CREATE TABLE odin_pg_test (id BIGSERIAL PRIMARY KEY, label TEXT, weight DOUBLE PRECISION, ok BOOLEAN)",
	)
	testing.expect_value(t, err, nil)
	defer sql.exec(db, "DROP TABLE odin_pg_test")

	// `?` placeholders are translated to `$n`.
	res, ierr := sql.exec(
		db,
		"INSERT INTO odin_pg_test (label, weight, ok) VALUES (?, ?, ?)",
		"first",
		f64(1.5),
		bool(true),
	)
	testing.expect_value(t, ierr, nil)
	testing.expect_value(t, res.rows_affected, 1)

	// Native `$n` placeholders also pass through unchanged.
	_, ierr = sql.exec(
		db,
		"INSERT INTO odin_pg_test (label, weight, ok) VALUES ($1, $2, $3)",
		"second",
		f64(2.5),
		bool(false),
	)
	testing.expect_value(t, ierr, nil)

	// Streaming query + struct scan.
	rows, qerr := sql.query(db, "SELECT id, label, weight, ok FROM odin_pg_test ORDER BY id")
	testing.expect_value(t, qerr, nil)
	defer sql.close_rows(&rows)

	got: [dynamic]Row
	defer delete(got)
	defer for r in got {delete(r.label)} // scan clones strings into context.allocator
	for sql.next(&rows) {
		r: Row
		serr := sql.scan(&rows, &r)
		testing.expect_value(t, serr, nil)
		append(&got, r)
	}
	testing.expect_value(t, len(got), 2)
	if len(got) == 2 {
		testing.expect_value(t, got[0].label, "first")
		testing.expect_value(t, got[0].weight, 1.5)
		testing.expect_value(t, got[0].ok, true)
		testing.expect_value(t, got[1].label, "second")
		testing.expect_value(t, got[1].ok, false)
	}
}

@(test)
test_params_and_null :: proc(t: ^testing.T) {
	dsn, ok := test_dsn()
	if !ok {return}

	db, err := sql.open(&driver, dsn)
	testing.expect_value(t, err, nil)
	if err != nil {return}
	defer sql.close(db)

	// Parameterized scalar select.
	{
		rows, qerr := sql.query(db, "SELECT ?::bigint + ?::bigint", i64(40), i64(2))
		testing.expect_value(t, qerr, nil)
		defer sql.close_rows(&rows)
		sum: i64 = -1
		if sql.next(&rows) {testing.expect_value(t, sql.scan(&rows, &sum), nil)}
		testing.expect_value(t, sum, 42)
	}

	// SQL NULL scanned into a Maybe(T) field stays None.
	{
		Opt :: struct {
			v: Maybe(i64),
		}
		rows, qerr := sql.query(db, "SELECT NULL::bigint AS v")
		testing.expect_value(t, qerr, nil)
		defer sql.close_rows(&rows)
		o: Opt
		if sql.next(&rows) {testing.expect_value(t, sql.scan(&rows, &o), nil)}
		_, present := o.v.?
		testing.expect(t, !present, "expected NULL to scan as None")
	}

	// query_row convenience: detaches the row + releases the conn; close_row
	// frees the buffered columns/values (scanned strings are caller-owned).
	{
		row := sql.query_row(db, "SELECT ?::text AS greeting", "hello")
		defer sql.close_row(&row)
		greeting: string
		testing.expect_value(t, sql.scan(&row, &greeting), nil)
		testing.expect_value(t, greeting, "hello")
		delete(greeting)
	}
}

@(test)
test_prepared_statement :: proc(t: ^testing.T) {
	dsn, ok := test_dsn()
	if !ok {return}

	db, err := sql.open(&driver, dsn)
	testing.expect_value(t, err, nil)
	if err != nil {return}
	defer sql.close(db)

	conn, cerr := sql.checkout(db)
	testing.expect_value(t, cerr, nil)
	if cerr != nil {return}
	defer sql.checkin(&conn)

	stmt, perr := sql.prepare(&conn, "SELECT ?::int * ?::int")
	testing.expect_value(t, perr, nil)
	if perr != nil {return}
	defer sql.close_stmt(&stmt)

	rows, serr := sql.stmt_query(&stmt, {i64(6), i64(7)})
	testing.expect_value(t, serr, nil)
	defer sql.close_rows(&rows)
	product: i64
	if sql.next(&rows) {testing.expect_value(t, sql.scan(&rows, &product), nil)}
	testing.expect_value(t, product, 42)
}

@(test)
test_transaction_rollback :: proc(t: ^testing.T) {
	dsn, ok := test_dsn()
	if !ok {return}

	db, err := sql.open(&driver, dsn)
	testing.expect_value(t, err, nil)
	if err != nil {return}
	defer sql.close(db)

	_, _ = sql.exec(db, "DROP TABLE IF EXISTS odin_pg_tx")
	_, err = sql.exec(db, "CREATE TABLE odin_pg_tx (n INT)")
	testing.expect_value(t, err, nil)
	defer sql.exec(db, "DROP TABLE odin_pg_tx")

	tx, terr := sql.begin(db)
	testing.expect_value(t, terr, nil)
	_, e := sql.exec(&tx, "INSERT INTO odin_pg_tx (n) VALUES (?)", i64(1))
	testing.expect_value(t, e, nil)
	testing.expect_value(t, sql.rollback(&tx), nil)

	rows, qerr := sql.query(db, "SELECT count(*) FROM odin_pg_tx")
	testing.expect_value(t, qerr, nil)
	defer sql.close_rows(&rows)
	n: i64 = -1
	if sql.next(&rows) {testing.expect_value(t, sql.scan(&rows, &n), nil)}
	testing.expect_value(t, n, 0)
}

// Verifies the advisory-lock contract against a real server: a lock held on one
// session blocks a second session's non-blocking attempt, and releasing it lets
// the second session through.
@(test)
test_advisory_lock :: proc(t: ^testing.T) {
	dsn, ok := test_dsn()
	if !ok {return}

	db, err := sql.open(&driver, dsn)
	testing.expect_value(t, err, nil)
	if err != nil {return}
	defer sql.close(db)

	KEY :: i64(990017)

	c1, e1 := sql.checkout(db)
	testing.expect_value(t, e1, nil)
	defer sql.checkin(&c1)
	c2, e2 := sql.checkout(db)
	testing.expect_value(t, e2, nil)
	defer sql.checkin(&c2)

	testing.expect(t, sql.supports_advisory_lock(&c1), "postgres supports advisory lock")

	// c1 takes the lock; c2's non-blocking try should fail while it is held.
	testing.expect_value(t, sql.advisory_lock(&c1, KEY), nil)
	testing.expect_value(t, try_lock(t, &c2, KEY), false)

	// After c1 releases, c2's try succeeds.
	testing.expect_value(t, sql.advisory_unlock(&c1, KEY), nil)
	testing.expect_value(t, try_lock(t, &c2, KEY), true)
	testing.expect_value(t, sql.advisory_unlock(&c2, KEY), nil)
}

// try_lock runs pg_try_advisory_lock (non-blocking) on conn and returns whether
// the lock was granted.
@(private = "file")
try_lock :: proc(t: ^testing.T, conn: ^sql.Conn, key: i64) -> bool {
	row := sql.query_row(conn, "SELECT pg_try_advisory_lock($1)", key)
	defer sql.close_row(&row)
	got: bool
	testing.expect_value(t, sql.scan(&row, &got), nil)
	return got
}

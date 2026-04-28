package sqlmock

import "core:testing"

import sql "../../database/sql"
import drv "../../database/sql/driver"

// User-under-test mirroring the demo in main.odin.
User :: struct {
	id:   i64,
	name: string,
	age:  int,
}

@(test)
test_query_with_canned_rows :: proc(t: ^testing.T) {
	mock, db := open()
	defer close(mock, db)

	returns_rows(
		expect_query(mock, "SELECT id, name, age FROM users"),
		{"id", "name", "age"},
		{
			{i64(1), "alice",   i64(30)},
			{i64(2), "bob",     i64(25)},
			{i64(3), "charlie", i64(35)},
		},
	)

	rows, err := sql.query(db, "SELECT id, name, age FROM users WHERE age > ?", i64(0))
	testing.expect_value(t, err, nil)
	defer sql.close_rows(&rows)

	got: [dynamic]User
	defer {
		for u in got {delete(u.name)} // sql.scan cloned strings into context.allocator
		delete(got)
	}

	for sql.next(&rows) {
		u: User
		serr := sql.scan(&rows, &u)
		testing.expect_value(t, serr, nil)
		append(&got, u)
	}

	testing.expect_value(t, len(got), 3)
	testing.expect_value(t, got[0].name, "alice")
	testing.expect_value(t, got[1].age, 25)
	testing.expect_value(t, got[2].id, i64(3))

	ok, msg := assert_done(mock)
	testing.expect(t, ok, msg)
}

@(test)
test_exec_returns_result :: proc(t: ^testing.T) {
	mock, db := open()
	defer close(mock, db)

	returns_result(
		expect_exec(mock, "INSERT INTO users"),
		last_insert_id = 42,
		rows_affected  = 1,
	)

	res, err := sql.exec(db, "INSERT INTO users (name) VALUES (?)", "dora")
	testing.expect_value(t, err, nil)
	testing.expect_value(t, res.last_insert_id, i64(42))
	testing.expect_value(t, res.rows_affected,  i64(1))

	ok, msg := assert_done(mock)
	testing.expect(t, ok, msg)
}

@(test)
test_unexpected_call_errors :: proc(t: ^testing.T) {
	mock, db := open()
	defer close(mock, db)

	// Register one exec expectation, but the code under test will issue two.
	expect_exec(mock, "INSERT")

	_, err1 := sql.exec(db, "INSERT INTO t VALUES (1)")
	testing.expect_value(t, err1, nil)

	_, err2 := sql.exec(db, "INSERT INTO t VALUES (2)")
	// The mock should refuse the second call.
	testing.expect(t, err2 != nil, "expected error on second exec")

	// All registered expectations were consumed; the failure was an *extra*
	// call, not an unconsumed expectation.
	ok, _ := assert_done(mock)
	testing.expect(t, ok, "registered expectation should be consumed")
}

@(test)
test_sql_substring_mismatch_errors :: proc(t: ^testing.T) {
	mock, db := open()
	defer close(mock, db)

	expect_exec(mock, "DELETE FROM users")

	_, err := sql.exec(db, "INSERT INTO users (name) VALUES ('x')")
	testing.expect(t, err != nil, "expected sql substring mismatch")
}

@(test)
test_transaction_flow :: proc(t: ^testing.T) {
	mock, db := open()
	defer close(mock, db)

	expect_begin(mock)
	returns_result(expect_exec(mock, "INSERT"), rows_affected = 1)
	expect_commit(mock)

	tx, berr := sql.begin(db)
	testing.expect_value(t, berr, nil)

	_, eerr := sql.exec(&tx, "INSERT INTO users (name) VALUES (?)", "edith")
	testing.expect_value(t, eerr, nil)

	cerr := sql.commit(&tx)
	testing.expect_value(t, cerr, nil)

	ok, msg := assert_done(mock)
	testing.expect(t, ok, msg)
}

@(test)
test_args_predicate :: proc(t: ^testing.T) {
	mock, db := open()
	defer close(mock, db)

	with_args(
		returns_result(expect_exec(mock, "UPDATE"), rows_affected = 1),
		proc(args: []drv.Value) -> bool {
			if len(args) != 2 {return false}
			name, ok1 := args[0].(string); _ = ok1
			id,   ok2 := args[1].(i64);    _ = ok2
			return name == "frank" && id == 7
		},
	)

	_, err := sql.exec(db, "UPDATE users SET name=? WHERE id=?", "frank", i64(7))
	testing.expect_value(t, err, nil)

	ok, msg := assert_done(mock)
	testing.expect(t, ok, msg)
}

@(test)
test_unconsumed_expectations_reported :: proc(t: ^testing.T) {
	mock, db := open()
	defer close(mock, db)

	expect_exec(mock, "INSERT")
	expect_exec(mock, "UPDATE")

	_, _ = sql.exec(db, "INSERT INTO x VALUES (1)")
	// Skip the UPDATE; assert_done should report it.

	ok, msg := assert_done(mock)
	testing.expect(t, !ok, "expected assert_done to fail")
	testing.expect(t, msg != "", "expected a diagnostic message")
}


package testing_example

import "core:testing"

import sql "../../database/sql"
import mock "../../drivers/mock"

@(test)
test_find_users_over :: proc(t: ^testing.T) {
	// Passing `t` makes close() assert every expectation was consumed exactly
	// once — no manual assert_done needed.
	m, db := mock.open(t)
	defer mock.close(m, db)

	// Tell the mock what the next query returns — as typed row structs.
	// Column names and value types come from User; no string column lists or
	// hand-wrapped Values, and a wrong-typed field would be a compile error.
	mock.returns_structs(
		mock.expect_query(m, "SELECT"),
		[]User{{id = 1, name = "Alice", age = 30}, {id = 3, name = "Carol", age = 41}},
	)

	users, err := find_users_over(db, 30)
	defer {
		for u in users {delete(u.name)} 	// scan clones strings into context.allocator
		delete(users)
	}


	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(users), 2)
	testing.expect_value(t, users[0].name, "Alice")
	testing.expect_value(t, users[1].age, i64(41))
}

@(test)
test_query_error_propagates :: proc(t: ^testing.T) {
	m, db := mock.open(t)
	defer mock.close(m, db)

	mock.returns_error(
		mock.expect_query(m, "SELECT"),
		sql.Driver_Error{code = 1, message = "boom"},
	)

	users, err := find_users_over(db, 0)
	defer delete(users)

	testing.expect(t, err != nil, "expected the query error to propagate")
}

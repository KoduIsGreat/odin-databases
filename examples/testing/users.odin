// testing — how to test database code without a real database.
//
// The mock driver (database:drivers/mock) lets a test set up expected queries and the
// rows/errors they return, so query logic can be exercised in isolation. This
// file holds the code under test; users_test.odin drives it through the mock.
//
// Run: just test-example testing   (or: odin test examples/testing)
package testing_example

import sql "database:sql"

User :: struct {
	id:   i64,
	name: string,
	age:  i64,
}

// find_users_over returns every user at least `min_age` years old. It is
// driver-agnostic: it talks only to ^sql.DB, so a test can hand it the mock
// driver's DB instead of SQLite.
find_users_over :: proc(db: ^sql.DB, min_age: i64) -> ([dynamic]User, sql.Error) {
	out: [dynamic]User
	rows, err := sql.query(db, "SELECT id, name, age FROM users WHERE age >= ?", min_age)
	if err != nil {
		return out, err
	}
	defer sql.rows_close(&rows)

	for sql.next(&rows) {
		u: User
		if serr := sql.scan(&rows, &u); serr != nil {
			return out, serr
		}
		append(&out, u)
	}
	// next() returns false for both a clean end-of-rows and a failure that ended
	// iteration early. Surface the latter rather than returning a silently
	// truncated result.
	if rerr := sql.rows_err(&rows); rerr != nil {
		return out, rerr
	}
	return out, nil
}

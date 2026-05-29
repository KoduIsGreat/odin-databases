package migrate

import "core:os"
import "core:path/filepath"
import "core:testing"

import sql "database:sql"
import mock "database:drivers/mock"
import sqlite "database:drivers/sqlite"

// A small fixed set of in-code migrations used across several tests. Backed by
// a package global so the slice can be returned safely (a compound literal
// would live on the caller's stack frame).
@(private = "file")
_fixture := [2]Migration {
	{
		version = 20260101000000,
		name = "create_users",
		up = "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
		down = "DROP TABLE users",
	},
	{
		version = 20260102000000,
		name = "add_email",
		up = "ALTER TABLE users ADD COLUMN email TEXT",
		down = "ALTER TABLE users DROP COLUMN email",
	},
}

fixture :: proc() -> []Migration {
	return _fixture[:]
}

// table_exists reports whether `name` is a table in the (SQLite) database.
table_exists :: proc(db: ^sql.DB, name: string) -> bool {
	row := sql.query_row(
		db,
		"SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?",
		name,
	)
	defer sql.close_row(&row)
	n: i64
	if sql.scan(&row, &n) != nil {return false}
	return n > 0
}

@(test)
test_up_is_idempotent :: proc(t: ^testing.T) {
	db, err := sql.open(&sqlite.driver, ":memory:")
	testing.expect_value(t, err, nil)
	defer sql.close(db)

	ms := fixture()

	applied, merr := up(db, ms)
	testing.expect_value(t, merr, nil)
	testing.expect_value(t, applied, 2)
	testing.expect(t, table_exists(db, "users"), "users table should exist after up")

	v, verr := current_version(db)
	testing.expect_value(t, verr, nil)
	testing.expect_value(t, v, 20260102000000)

	// Running up again applies nothing.
	applied2, merr2 := up(db, ms)
	testing.expect_value(t, merr2, nil)
	testing.expect_value(t, applied2, 0)
}

@(test)
test_status :: proc(t: ^testing.T) {
	db, err := sql.open(&sqlite.driver, ":memory:")
	testing.expect_value(t, err, nil)
	defer sql.close(db)

	ms := fixture()
	// Apply only the first migration via a partial target.
	terr := to(db, ms, 20260101000000)
	testing.expect_value(t, terr, nil)

	st, serr := status(db, ms)
	testing.expect_value(t, serr, nil)
	defer destroy_statuses(st)

	testing.expect_value(t, len(st), 2)
	testing.expect(t, st[0].applied, "first migration should be applied")
	testing.expect(t, !st[1].applied, "second migration should be pending")
}

@(test)
test_down_one_step :: proc(t: ^testing.T) {
	db, err := sql.open(&sqlite.driver, ":memory:")
	testing.expect_value(t, err, nil)
	defer sql.close(db)

	ms := fixture()
	_, merr := up(db, ms)
	testing.expect_value(t, merr, nil)

	// Roll back the most recent migration (add_email).
	derr := down(db, ms)
	testing.expect_value(t, derr, nil)

	v, _ := current_version(db)
	testing.expect_value(t, v, 20260101000000)
	testing.expect(t, table_exists(db, "users"), "users table should still exist")
}

@(test)
test_to_target_rolls_back_and_forward :: proc(t: ^testing.T) {
	db, err := sql.open(&sqlite.driver, ":memory:")
	testing.expect_value(t, err, nil)
	defer sql.close(db)

	ms := fixture()
	_, merr := up(db, ms)
	testing.expect_value(t, merr, nil)

	// Down to zero — everything rolled back.
	testing.expect_value(t, to(db, ms, 0), nil)
	v0, _ := current_version(db)
	testing.expect_value(t, v0, 0)
	testing.expect(t, !table_exists(db, "users"), "users table should be gone after to(0)")

	// Forward again to the latest.
	testing.expect_value(t, to(db, ms, 20260102000000), nil)
	v1, _ := current_version(db)
	testing.expect_value(t, v1, 20260102000000)
}

@(test)
test_to_unknown_version :: proc(t: ^testing.T) {
	db, err := sql.open(&sqlite.driver, ":memory:")
	testing.expect_value(t, err, nil)
	defer sql.close(db)

	merr := to(db, fixture(), 99999999999999)
	me, ok := merr.(Migrate_Error)
	testing.expect(t, ok, "expected a Migrate_Error")
	testing.expect_value(t, me.kind, Migrate_Error_Kind.Unknown_Version)
}

@(test)
test_irreversible_down :: proc(t: ^testing.T) {
	db, err := sql.open(&sqlite.driver, ":memory:")
	testing.expect_value(t, err, nil)
	defer sql.close(db)

	ms := []Migration {
		{
			version = 20260101000000,
			name = "seed",
			up = "CREATE TABLE t (id INTEGER)",
			down = "", // irreversible
		},
	}
	_, merr := up(db, ms)
	testing.expect_value(t, merr, nil)

	derr := down(db, ms)
	me, ok := derr.(Migrate_Error)
	testing.expect(t, ok, "expected a Migrate_Error")
	testing.expect_value(t, me.kind, Migrate_Error_Kind.Irreversible)
}

@(test)
test_duplicate_version :: proc(t: ^testing.T) {
	db, err := sql.open(&sqlite.driver, ":memory:")
	testing.expect_value(t, err, nil)
	defer sql.close(db)

	ms := []Migration {
		{version = 1, name = "a", up = "CREATE TABLE a (id INTEGER)"},
		{version = 1, name = "b", up = "CREATE TABLE b (id INTEGER)"},
	}
	_, merr := up(db, ms)
	me, ok := merr.(Migrate_Error)
	testing.expect(t, ok, "expected a Migrate_Error")
	testing.expect_value(t, me.kind, Migrate_Error_Kind.Duplicate_Version)
}

@(test)
test_multi_statement_migration :: proc(t: ^testing.T) {
	db, err := sql.open(&sqlite.driver, ":memory:")
	testing.expect_value(t, err, nil)
	defer sql.close(db)

	// A single migration whose up creates two tables (exercises the SQLite
	// driver's multi-statement exec path).
	ms := []Migration {
		{
			version = 20260101000000,
			name = "two_tables",
			up = "CREATE TABLE a (id INTEGER);\nCREATE TABLE b (id INTEGER);",
			down = "DROP TABLE a; DROP TABLE b;",
		},
	}
	applied, merr := up(db, ms)
	testing.expect_value(t, merr, nil)
	testing.expect_value(t, applied, 1)
	testing.expect(t, table_exists(db, "a"), "table a should exist")
	testing.expect(t, table_exists(db, "b"), "table b should exist")

	testing.expect_value(t, down(db, ms), nil)
	testing.expect(t, !table_exists(db, "a"), "table a should be dropped")
	testing.expect(t, !table_exists(db, "b"), "table b should be dropped")
}

@(test)
test_from_dir :: proc(t: ^testing.T) {
	root, _ := os.temp_dir(context.temp_allocator)
	dir, _ := filepath.join({root, "odin_migrate_test"}, context.temp_allocator)
	_ = os.make_directory(dir) // ignore error (may already exist)
	defer {
		rm(dir, "20260101120000_create_users.up.sql")
		rm(dir, "20260101120000_create_users.down.sql")
		rm(dir, "20260102120000_add_index.up.sql")
		rm(dir, "README.md")
		_ = os.remove(dir)
	}

	write_file(t, dir, "20260101120000_create_users.up.sql", "CREATE TABLE users (id INTEGER PRIMARY KEY);")
	write_file(t, dir, "20260101120000_create_users.down.sql", "DROP TABLE users;")
	// Forward-only migration (no .down.sql).
	write_file(t, dir, "20260102120000_add_index.up.sql", "CREATE INDEX idx_users_id ON users (id);")
	// A non-migration file that must be ignored.
	write_file(t, dir, "README.md", "ignore me")

	ms, lerr := from_dir(dir)
	testing.expect_value(t, lerr, nil)
	defer destroy_migrations(ms)

	testing.expect_value(t, len(ms), 2)
	testing.expect_value(t, ms[0].version, 20260101120000)
	testing.expect_value(t, ms[0].name, "create_users")
	testing.expect_value(t, ms[0].down, "DROP TABLE users;")
	testing.expect_value(t, ms[1].version, 20260102120000)
	testing.expect_value(t, ms[1].down, "") // no down file

	// And they actually run.
	db, derr := sql.open(&sqlite.driver, ":memory:")
	testing.expect_value(t, derr, nil)
	defer sql.close(db)
	applied, aerr := up(db, ms)
	testing.expect_value(t, aerr, nil)
	testing.expect_value(t, applied, 2)
	testing.expect(t, table_exists(db, "users"), "users table should exist")
}

// Against a driver that supports advisory locking, up() must take the lock
// once around the run and release it once. We drive it with the mock so we can
// assert the lock/unlock counts and the exact statement sequence.
@(test)
test_up_takes_advisory_lock :: proc(t: ^testing.T) {
	m, db := mock.open(t)
	defer mock.close(m, db)

	// The statements up() issues for one pending migration, in order:
	mock.expect_exec(m, "CREATE TABLE IF NOT EXISTS") // ensure_table
	mock.returns_rows(mock.expect_query(m, "SELECT version"), {"version"}, {}) // applied: none
	mock.expect_begin(m)
	mock.expect_exec(m, "CREATE TABLE widgets") // the migration body
	mock.expect_exec(m, "INSERT INTO schema_migrations")
	mock.expect_commit(m)

	ms := []Migration {
		{version = 20260101000000, name = "widgets", up = "CREATE TABLE widgets (id INTEGER)"},
	}
	applied, err := up(db, ms)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, applied, 1)
	testing.expect_value(t, m.lock_count, 1)
	testing.expect_value(t, m.unlock_count, 1)
}

@(test)
test_sqlite_has_no_advisory_lock :: proc(t: ^testing.T) {
	db, err := sql.open(&sqlite.driver, ":memory:")
	testing.expect_value(t, err, nil)
	defer sql.close(db)

	conn, cerr := sql.checkout(db)
	testing.expect_value(t, cerr, nil)
	defer sql.checkin(&conn)

	testing.expect(t, !sql.supports_advisory_lock(&conn), "sqlite is single-writer; no advisory lock")
	// The no-op lock/unlock are still safe to call.
	testing.expect_value(t, sql.advisory_lock(&conn, 1), nil)
	testing.expect_value(t, sql.advisory_unlock(&conn, 1), nil)

	// And up() still works (the runner skips locking when unsupported).
	applied, merr := up(db, fixture())
	testing.expect_value(t, merr, nil)
	testing.expect_value(t, applied, 2)
}

@(private = "file")
write_file :: proc(t: ^testing.T, dir, name, contents: string) {
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	werr := os.write_entire_file(path, transmute([]byte)contents)
	testing.expect_value(t, werr, nil)
}

@(private = "file")
rm :: proc(dir, name: string) {
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	_ = os.remove(path)
}

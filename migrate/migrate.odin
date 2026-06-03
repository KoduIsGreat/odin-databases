// Package migrate is a small, driver-agnostic schema-migration runner for the
// `database:sql` core. It applies an ordered set of migrations against a `^sql.DB`,
// records which versions have been applied in a `schema_migrations` table, and
// supports rolling them back.
//
// The runner operates purely on a `[]Migration` slice — it does not care where
// the migrations come from. `from_dir` (see loader.odin) is one front-end that
// loads them from `.sql` files on disk; you can equally build the slice by hand
// (the `up`/`down` fields are just SQL strings). This mirrors `schemagen`'s
// design: decouple the source of the schema from the thing that consumes it.
//
// Versioning
//
// Each migration carries an i64 `version`. By convention (and as produced by
// `from_dir`) the version is a 14-digit `YYYYMMDDHHMMSS` timestamp, so ordering
// is by creation time and two branches rarely collide. The runner only requires
// that versions are unique and orderable.
//
// Atomicity
//
// Every migration body and its `schema_migrations` bookkeeping row are applied
// inside a single transaction, so a failed migration leaves nothing
// half-applied. Both the SQLite and PostgreSQL drivers have transactional DDL,
// so this holds for schema changes too.
//
// Concurrency
//
// The runner does not take a distributed lock — run migrations from a single
// process at startup (or behind your own lock). Within a process, `^sql.DB` is
// safe to share across threads, but migrations should be run once, serially.
package migrate

import "core:slice"
import "core:strings"
import "core:time"

import sql "database:sql"

// MIGRATIONS_TABLE is the bookkeeping table the runner maintains. One row is
// inserted per applied migration (version + name + applied_at), giving a full
// history rather than a single "current version" marker.
MIGRATIONS_TABLE :: "schema_migrations"

// LOCK_KEY is the advisory-lock key the runner uses (an arbitrary fixed i64,
// the ASCII bytes of "odin_mig"). When the driver supports advisory locking
// (e.g. PostgreSQL), up/down/to take this lock for the duration of the run so
// concurrent processes serialize their migrations instead of racing.
@(private)
LOCK_KEY :: i64(0x6F64696E5F6D6967)

// Migration is a single, versioned schema change.
//
// `up` is the SQL applied to move the schema forward; `down` reverts it. Both
// may contain multiple `;`-separated statements. A `down` of "" marks the
// migration irreversible — rolling back past it returns a .Irreversible error.
Migration :: struct {
	version: i64,    // ordering key; by convention a YYYYMMDDHHMMSS timestamp
	name:    string, // human-readable label (from the filename, in from_dir)
	up:      string, // SQL to apply
	down:    string, // SQL to revert; "" = irreversible
}

// Status reports, for one known migration, whether it has been applied.
Status :: struct {
	version:    i64,
	name:       string,
	applied:    bool,
	applied_at: time.Time, // zero value if not applied
}

// Error is returned by the runner. A DB/driver failure surfaces as the wrapped
// `sql.Error`; problems specific to migration handling surface as Migrate_Error.
Error :: union {
	sql.Error,
	Migrate_Error,
}

Migrate_Error_Kind :: enum {
	Bad_Filename,      // a file name didn't match <version>_<name>.(up|down).sql
	Duplicate_Version, // two migrations share the same version
	Missing_Up,        // a .down.sql with no matching .up.sql
	Irreversible,      // tried to roll back a migration whose down is ""
	Unknown_Version,   // a target/applied version isn't among the migrations given
	Read_Failed,       // directory listing or file read failed (from_dir)
}

Migrate_Error :: struct {
	kind:    Migrate_Error_Kind,
	version: i64,    // the offending version, when applicable
	detail:  string, // extra context (a filename, a name, an OS error)
}

// up applies every migration not yet recorded, in ascending version order, and
// returns how many were applied. It is idempotent: already-applied versions are
// skipped, so it is safe to call on every startup. When the driver supports
// advisory locking, the run is serialized across processes (see LOCK_KEY).
up :: proc(db: ^sql.DB, migrations: []Migration) -> (applied: int, err: Error) {
	sorted := validated(migrations) or_return // cheap, lock-free validation first

	conn := sql.checkout(db) or_return
	defer sql.checkin(&conn)
	locked := acquire_lock(&conn) or_return
	defer if locked {sql.advisory_unlock(&conn, LOCK_KEY)}

	ensure_table(&conn) or_return
	done := applied_versions(&conn, context.temp_allocator) or_return

	for m in sorted {
		if slice.contains(done, m.version) {continue}
		apply_one(&conn, m) or_return
		applied += 1
	}
	return applied, nil
}

// down rolls back the single most-recently-applied migration (the highest
// applied version). It is a no-op if nothing has been applied. The matching
// migration must be present in `migrations` and have a non-empty `down`.
down :: proc(db: ^sql.DB, migrations: []Migration) -> Error {
	conn := sql.checkout(db) or_return
	defer sql.checkin(&conn)
	locked := acquire_lock(&conn) or_return
	defer if locked {sql.advisory_unlock(&conn, LOCK_KEY)}

	ensure_table(&conn) or_return
	done := applied_versions(&conn, context.temp_allocator) or_return
	if len(done) == 0 {return nil}

	last := done[len(done) - 1] // applied_versions returns ascending order
	for m in migrations {
		if m.version == last {
			return revert_one(&conn, m)
		}
	}
	return Migrate_Error{kind = .Unknown_Version, version = last}
}

// to brings the schema to exactly `target`: every migration with version <=
// target is applied and every one with version > target is rolled back. Pass
// target = 0 to roll everything back. `target` must be 0 or one of the given
// migration versions.
to :: proc(db: ^sql.DB, migrations: []Migration, target: i64) -> Error {
	sorted := validated(migrations) or_return

	if target != 0 {
		known := false
		for m in sorted {
			if m.version == target {known = true;break}
		}
		if !known {return Migrate_Error{kind = .Unknown_Version, version = target}}
	}

	conn := sql.checkout(db) or_return
	defer sql.checkin(&conn)
	locked := acquire_lock(&conn) or_return
	defer if locked {sql.advisory_unlock(&conn, LOCK_KEY)}

	ensure_table(&conn) or_return
	done := applied_versions(&conn, context.temp_allocator) or_return

	// Roll back everything above the target, newest first.
	#reverse for m in sorted {
		if m.version > target && slice.contains(done, m.version) {
			revert_one(&conn, m) or_return
		}
	}
	// Apply everything up to and including the target, oldest first.
	for m in sorted {
		if m.version <= target && !slice.contains(done, m.version) {
			apply_one(&conn, m) or_return
		}
	}
	return nil
}

// current_version returns the highest applied migration version, or 0 if none
// have been applied. It creates the bookkeeping table if necessary. (Read-only;
// no advisory lock is taken.)
current_version :: proc(db: ^sql.DB) -> (version: i64, err: Error) {
	conn := sql.checkout(db) or_return
	defer sql.checkin(&conn)
	ensure_table(&conn) or_return
	row := sql.query_row(&conn, "SELECT COALESCE(MAX(version), 0) FROM " + MIGRATIONS_TABLE)
	defer sql.close_row(&row)
	v: i64
	if e := sql.scan(&row, &v); e != nil {return 0, e}
	return v, nil
}

// status returns one Status per migration (in ascending version order),
// reporting whether each has been applied and when. The returned slice and its
// cloned `name` strings are allocated with `allocator`; free them with
// destroy_statuses. (Read-only; no advisory lock is taken.)
status :: proc(
	db: ^sql.DB,
	migrations: []Migration,
	allocator := context.allocator,
) -> (
	out: []Status,
	err: Error,
) {
	conn := sql.checkout(db) or_return
	defer sql.checkin(&conn)
	ensure_table(&conn) or_return

	applied := make(map[i64]time.Time, allocator = context.temp_allocator)
	rows := sql.query(&conn, "SELECT version, applied_at FROM " + MIGRATIONS_TABLE) or_return
	defer sql.close_rows(&rows)
	for sql.next(&rows) {
		v: i64
		at: time.Time
		if e := sql.scan(&rows, &v, &at); e != nil {return nil, e}
		applied[v] = at
	}
	// next() stops on both clean EOF and a mid-stream failure; a truncated read
	// here would make us treat already-applied migrations as pending.
	if e := sql.rows_err(&rows); e != nil {return nil, e}

	sorted := validated(migrations) or_return
	res := make([dynamic]Status, 0, len(sorted), allocator)
	for m in sorted {
		at, ok := applied[m.version]
		append(
			&res,
			Status {
				version = m.version,
				name = strings.clone(m.name, allocator),
				applied = ok,
				applied_at = at,
			},
		)
	}
	return res[:], nil
}

// destroy_statuses frees a slice returned by status (and its cloned names).
destroy_statuses :: proc(statuses: []Status, allocator := context.allocator) {
	for s in statuses {
		delete(s.name, allocator)
	}
	delete(statuses, allocator)
}

// --- internals ---------------------------------------------------------------

// acquire_lock takes the migrations advisory lock if the driver supports it,
// reporting whether a lock was actually taken (so the caller knows whether to
// release one). A no-op returning false on drivers without locking (SQLite).
@(private)
acquire_lock :: proc(conn: ^sql.Conn) -> (locked: bool, err: Error) {
	if !sql.supports_advisory_lock(conn) {return false, nil}
	if e := sql.advisory_lock(conn, LOCK_KEY); e != nil {return false, e}
	return true, nil
}

@(private)
ensure_table :: proc(conn: ^sql.Conn) -> Error {
	// Portable across SQLite and PostgreSQL: BIGINT/TEXT/TIMESTAMP are native to
	// both, and IF NOT EXISTS makes this safe to run on every startup. (On
	// SQLite, BIGINT PRIMARY KEY is NOT a rowid alias, so the explicit version
	// values are stored as given.)
	_, e := sql.exec(
		conn,
		"CREATE TABLE IF NOT EXISTS " +
		MIGRATIONS_TABLE +
		" (version BIGINT PRIMARY KEY, name TEXT NOT NULL, applied_at TIMESTAMP NOT NULL)",
	)
	if e != nil {return e}
	return nil
}

// validated returns a version-sorted copy of `migrations` (in the temp
// allocator) after checking that no two share a version.
@(private)
validated :: proc(migrations: []Migration) -> ([]Migration, Error) {
	out := make([]Migration, len(migrations), context.temp_allocator)
	copy(out, migrations)
	slice.sort_by(out, proc(a, b: Migration) -> bool {return a.version < b.version})
	for i in 1 ..< len(out) {
		if out[i].version == out[i - 1].version {
			return nil, Migrate_Error{kind = .Duplicate_Version, version = out[i].version}
		}
	}
	return out, nil
}

@(private)
applied_versions :: proc(
	conn: ^sql.Conn,
	allocator := context.allocator,
) -> (
	versions: []i64,
	err: Error,
) {
	rows := sql.query(conn, "SELECT version FROM " + MIGRATIONS_TABLE + " ORDER BY version") or_return
	defer sql.close_rows(&rows)
	list := make([dynamic]i64, allocator)
	for sql.next(&rows) {
		v: i64
		if e := sql.scan(&rows, &v); e != nil {
			delete(list)
			return nil, e
		}
		append(&list, v)
	}
	if e := sql.rows_err(&rows); e != nil {
		delete(list)
		return nil, e
	}
	return list[:], nil
}

@(private)
apply_one :: proc(conn: ^sql.Conn, m: Migration) -> Error {
	tx := sql.begin(conn) or_return
	if _, e := sql.exec(&tx, m.up); e != nil {
		sql.rollback(&tx)
		return e
	}
	if _, e := sql.exec(
		&tx,
		"INSERT INTO " + MIGRATIONS_TABLE + " (version, name, applied_at) VALUES (?, ?, ?)",
		m.version,
		m.name,
		time.now(),
	); e != nil {
		sql.rollback(&tx)
		return e
	}
	if e := sql.commit(&tx); e != nil {return e}
	return nil
}

@(private)
revert_one :: proc(conn: ^sql.Conn, m: Migration) -> Error {
	if m.down == "" {
		return Migrate_Error{kind = .Irreversible, version = m.version, detail = m.name}
	}
	tx := sql.begin(conn) or_return
	if _, e := sql.exec(&tx, m.down); e != nil {
		sql.rollback(&tx)
		return e
	}
	if _, e := sql.exec(
		&tx,
		"DELETE FROM " + MIGRATIONS_TABLE + " WHERE version = ?",
		m.version,
	); e != nil {
		sql.rollback(&tx)
		return e
	}
	if e := sql.commit(&tx); e != nil {return e}
	return nil
}

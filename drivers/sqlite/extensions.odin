// SQLite loadable-extension support.
//
// Statically-compiled extensions (JSON1, FTS5, R*Tree — see build_libs.sh) are
// always available through normal SQL. These procs additionally let you load a
// run-time extension (a shared library) into a connection via SQLite's
// C-API loader.
//
// Loading is OFF by default (a SQLite security default); call
// enable_load_extension(conn, true) first. Both procs operate on a single
// checked-out connection:
//
//   conn, _ := sql.checkout(db)
//   defer sql.checkin(&conn)
//   sqlite.enable_load_extension(&conn, true)
//   sqlite.load_extension(&conn, "/path/to/ext")  // e.g. "./uuid"
//
// Extensions are per-connection. With a pooled DB this affects only the one
// checked-out connection — for pool-wide use, set max_open to 1, or load the
// extension on each connection you check out before using it.
package sqlite

import "core:strings"

import sql "../../database/sql"
import drv "../../database/sql/driver"
import sql3 "../../bindings/sqlite/sqlite"

// enable_load_extension toggles SQLite's C-API extension loader for the
// connection. Call with `true` before load_extension.
enable_load_extension :: proc(conn: ^sql.Conn, on: bool) -> drv.Error {
	sc := cast(^Sqlite_Conn)conn.handle
	if sql3.enable_load_extension(sc.db, 1 if on else 0) != sql3.OK {
		return make_error(sc.db)
	}
	return nil
}

// load_extension loads the shared library at `path` into the connection.
// `entry` is the optional entry-point symbol ("" → SQLite's default). Returns
// a Driver_Error (with SQLite's message) on failure.
load_extension :: proc(conn: ^sql.Conn, path: string, entry := "") -> drv.Error {
	sc := cast(^Sqlite_Conn)conn.handle

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	centry: cstring = nil
	if entry != "" {
		centry = strings.clone_to_cstring(entry, context.temp_allocator)
	}

	if sql3.load_extension(sc.db, cpath, centry, nil) != sql3.OK {
		return make_error(sc.db)
	}
	return nil
}

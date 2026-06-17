package dburl

import "core:fmt"
import "core:strings"

import sql "database:sql"

import pg "database:drivers/postgres"
import sqlite "database:drivers/sqlite"

// DuckDB is opt-in (large static archives + libduckdb loader path). Odin forbids
// `import` inside a `when`, so — like tools/schemagen — the import is
// unconditional and `duckdb` is referenced only under `when DUCKDB_ENABLED`, so a
// default build neither links nor requires libduckdb. Enable with
// -define:DATABASE_URL_DUCKDB=true.
DUCKDB_ENABLED :: #config(DATABASE_URL_DUCKDB, false)
import duckdb "database:drivers/duckdb"

when DUCKDB_ENABLED {
	SUPPORTED_SCHEMES :: "postgres, postgresql, sqlite, sqlite3, duckdb"
} else {
	SUPPORTED_SCHEMES :: "postgres, postgresql, sqlite, sqlite3"
}

// Error is what open_url returns: either the scheme could not be routed to a
// driver (Scheme_Error), or sql.open / the driver itself failed (sql.Error).
Error :: union {
	Scheme_Error,
	sql.Error,
}

// Scheme_Error reports a URL whose scheme dburl does not recognize (scheme set)
// or that carries no scheme at all (scheme == ""). Both fields BORROW from the
// url passed to open_url / driver_for_url; they are valid as long as it is.
Scheme_Error :: struct {
	url:    string,
	scheme: string,
}

// driver_for_url resolves a URL to a driver and the DSN that driver expects,
// without opening anything (no I/O). ok is false for an unknown or missing
// scheme, in which case `scheme` is the extracted scheme ("" if none).
//
// The DSN handed back differs by family: postgres parses the URL itself, so it
// receives the URL verbatim; file-based engines (sqlite, duckdb) receive just
// the path, with the scheme and any empty "//" authority stripped — so
// "sqlite:///abs/db" -> "/abs/db", "sqlite://rel.db" -> "rel.db", and
// "sqlite::memory:" -> ":memory:".
driver_for_url :: proc(
	url: string,
) -> (
	driver: ^sql.Driver,
	dsn: string,
	scheme: string,
	ok: bool,
) {
	colon := strings.index_byte(url, ':')
	if colon <= 0 {
		return nil, "", "", false // no scheme
	}
	scheme = url[:colon]
	folded := strings.to_lower(scheme, context.temp_allocator)

	// Path form for file-based drivers: drop "scheme:" and an optional empty
	// "//" authority. Postgres ignores this and takes the URL verbatim.
	path := url[colon + 1:]
	if strings.has_prefix(path, "//") {
		path = path[2:]
	}

	switch folded {
	case "postgres", "postgresql":
		return &pg.driver, url, scheme, true
	case "sqlite", "sqlite3":
		return &sqlite.driver, path, scheme, true
	}

	when DUCKDB_ENABLED {
		if folded == "duckdb" {
			return &duckdb.driver, path, scheme, true
		}
	}

	return nil, "", scheme, false
}

// open_url picks a driver from url's scheme and opens a DB, mirroring sql.open
// (no connection is established until first use). The allocator backs the pool
// and driver connections, as in sql.open.
open_url :: proc(url: string, allocator := context.allocator) -> (^sql.DB, Error) {
	driver, dsn, scheme, ok := driver_for_url(url)
	if !ok {
		return nil, Scheme_Error{url = url, scheme = scheme}
	}
	db, oerr := sql.open(driver, dsn, allocator)
	if oerr != nil {
		return nil, oerr
	}
	return db, nil
}

// error_to_string renders a dburl Error for display. Scheme failures name the
// offending scheme and the supported set; driver/open failures delegate to
// sql.err_to_string. The result is allocated from `allocator`; the caller owns it.
error_to_string :: proc(err: Error, allocator := context.allocator) -> string {
	switch e in err {
	case Scheme_Error:
		if e.scheme == "" {
			return fmt.aprintf(
				"dburl: no scheme in URL %q (expected one of: %s)",
				e.url,
				SUPPORTED_SCHEMES,
				allocator = allocator,
			)
		}
		return fmt.aprintf(
			"dburl: unsupported URL scheme %q (supported: %s)",
			e.scheme,
			SUPPORTED_SCHEMES,
			allocator = allocator,
		)
	case sql.Error:
		return sql.err_to_string(e, allocator)
	}
	return strings.clone("dburl: nil error", allocator)
}

package sql

import "core:time"

// Conn is an explicitly checked-out connection from the pool.
// The caller owns it and must return it with checkin().
// All operations on a Conn use its underlying connection directly —
// no pool interaction until checkin.
Conn :: struct {
	db:         ^DB,
	handle:     Conn_Handle,
	driver:     ^Driver,
	created_at: time.Time,
}

// checkout acquires a connection from the pool.
// The caller must call checkin() when done.
checkout :: proc(db: ^DB) -> (Conn, Error) {
	handle, created_at, err := pool_acquire(db)
	if err != nil {return {}, err}
	return Conn{db = db, handle = handle, driver = db.driver, created_at = created_at}, nil
}

// checkin returns a connection to the pool.
checkin :: proc(conn: ^Conn) -> Error {
	pool_release(conn.db, conn.handle, conn.created_at)
	conn^ = {} // zero out to prevent use-after-checkin
	return nil
}

@(private)
conn_exec :: proc(conn: ^Conn, query_str: string, args: []Value) -> (Result, Error) {
	return conn.driver.exec(conn.handle, query_str, args)
}

@(private)
conn_query :: proc(conn: ^Conn, query_str: string, args: []Value) -> (Rows, Error) {
	handle, err := conn.driver.query(conn.handle, query_str, args)
	if err != nil {return {}, err}

	// Rows from an explicit Conn do NOT release the connection.
	// The caller manages the Conn lifecycle separately.
	return Rows{db = nil, conn = conn.handle, handle = handle, driver = conn.driver}, nil
}

package sql

// Stmt is a prepared statement bound to a connection.
// The Stmt does NOT own the connection — the caller manages the
// Conn (or Tx) lifecycle independently. Close all Stmts before
// returning the connection to the pool.
//
// query is the SQL text the statement was prepared with, retained (borrowed,
// not cloned) so later stmt_exec/stmt_query failures can surface it in the
// error. Keep the string alive for the Stmt's lifetime — automatic for
// literals, the common case.
Stmt :: struct {
	conn_handle: Conn_Handle,
	handle:      Stmt_Handle,
	driver:      ^Driver,
	query:       string,
	closed:      bool,
}

// prepare on an explicit Conn.
@(private)
conn_prepare :: proc(conn: ^Conn, query_str: string, loc := #caller_location) -> (Stmt, Error) {
	handle, err := conn.driver.prepare(conn.handle, query_str)
	if err != nil {return {}, with_query(err, query_str, loc)}

	return Stmt {
			conn_handle = conn.handle,
			handle = handle,
			driver = conn.driver,
			query = query_str,
		}, nil
}

// prepare within a transaction (uses the Tx's underlying connection).
@(private)
tx_prepare :: proc(tx: ^Tx, query_str: string, loc := #caller_location) -> (Stmt, Error) {
	if tx.done {
		return {}, with_query(
			Driver_Error{code = 0, message = "sql: transaction already completed"},
			query_str,
			loc,
		)
	}

	handle, err := tx.driver.prepare(tx.conn_handle, query_str)
	if err != nil {return {}, with_query(err, query_str, loc)}

	return Stmt {
			conn_handle = tx.conn_handle,
			handle = handle,
			driver = tx.driver,
			query = query_str,
		}, nil
}

// stmt_exec executes a prepared statement that doesn't return rows.
stmt_exec :: proc(stmt: ^Stmt, args: []Value, loc := #caller_location) -> (Result, Error) {
	if stmt.closed {
		return {}, with_query(
			Driver_Error{code = 0, message = "sql: statement is closed"},
			stmt.query,
			loc,
		)
	}

	result, err := stmt.driver.stmt_exec(stmt.handle, args)
	if err != nil {return {}, with_query(err, stmt.query, loc)}

	if stmt.driver.stmt_reset != nil {
		reset_err := stmt.driver.stmt_reset(stmt.handle)
		if reset_err != nil {return result, with_query(reset_err, stmt.query, loc)}
	}

	return result, nil
}

// stmt_query executes a prepared statement that returns rows.
// The returned Rows does NOT own the connection. Close the Rows
// before closing the Stmt or returning the connection.
stmt_query :: proc(stmt: ^Stmt, args: []Value, loc := #caller_location) -> (Rows, Error) {
	if stmt.closed {
		return {}, with_query(
			Driver_Error{code = 0, message = "sql: statement is closed"},
			stmt.query,
			loc,
		)
	}

	handle, err := stmt.driver.stmt_query(stmt.handle, args)
	if err != nil {return {}, with_query(err, stmt.query, loc)}

	return Rows {
			db     = nil, // does not own the connection
			conn   = stmt.conn_handle,
			handle = handle,
			driver = stmt.driver,
			query  = stmt.query,
			loc    = loc,
		}, nil
}

// close_stmt finalizes the prepared statement.
// Does NOT return the connection to the pool — the caller manages that.
stmt_close :: proc(stmt: ^Stmt) -> Error {
	if stmt.closed {return nil}
	stmt.closed = true
	return stmt.driver.stmt_close(stmt.handle)
}

// duckdb — the core database:sql API with the preliminary DuckDB driver.
//
// Covers: opening a DB with the DuckDB driver, exec, a transaction with a
// reused prepared statement, query_row, reflective struct scanning, and a
// small analytical aggregation (DuckDB's bread and butter).
//
// The DuckDB driver links a prebuilt shared library that must be on the loader
// path at run time, so use the recipe (it sets *_LIBRARY_PATH for you):
//
//     just duckdb-lib            # once, to fetch the library
//     just run-duckdb-example
//
// The package is `main` (not `duckdb`) so it can import the `duckdb` driver
// package without a name clash.
package main

import "core:fmt"
import vmem "core:mem/virtual"

import duck "database:drivers/duckdb"
import sql "database:sql"

Trade :: struct {
	id:     i64,
	symbol: string,
	qty:    i64,
	price:  f64,
}

// seed creates the table and inserts a handful of trades inside a transaction,
// reusing one prepared statement for every row.
seed :: proc(db: ^sql.DB) -> sql.Error {
	sql.exec(
		db,
		"CREATE TABLE trades (id INTEGER, symbol VARCHAR, qty BIGINT, price DOUBLE)",
	) or_return

	tx := sql.begin(db) or_return
	stmt, perr := sql.prepare(&tx, "INSERT INTO trades VALUES (?, ?, ?, ?)")
	if perr != nil {
		sql.rollback(&tx)
		return perr
	}
	defer sql.stmt_close(&stmt)

	rows := [?][4]sql.Value {
		{i64(1), "AAPL", i64(10), f64(190.12)},
		{i64(2), "AAPL", i64(5), f64(191.40)},
		{i64(3), "MSFT", i64(8), f64(420.05)},
		{i64(4), "MSFT", i64(3), f64(419.10)},
		{i64(5), "NVDA", i64(2), f64(1180.55)},
	}
	for &r in rows {
		if _, err := sql.stmt_exec(&stmt, r[:]); err != nil {
			sql.rollback(&tx)
			return err
		}
	}
	return sql.commit(&tx)
}

main :: proc() {
	// Use an arena for scan output (cloned strings/bytes); pool internals use
	// the allocator passed to open().
	arena: vmem.Arena
	if err := vmem.arena_init_growing(&arena); err != nil {
		fmt.eprintfln("arena: %v", err)
		return
	}
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	// :memory: gives each pooled connection its own in-memory database, so pin
	// the pool to one connection to share state across statements.
	db, open_err := sql.open(&duck.driver, ":memory:")
	if open_err != nil {
		fmt.eprintfln("open: %v", open_err)
		return
	}
	sql.set_max_open_conns(db, 1)
	defer sql.close(db)

	if err := seed(db); err != nil {
		fmt.eprintfln("seed: %v", err)
		return
	}

	// query_row: a single-row convenience that detaches and frees its conn.
	fmt.println("--- query_row: most expensive trade ---")
	{
		row := sql.query_row(db, "SELECT * FROM trades ORDER BY price DESC LIMIT 1")
		defer sql.close_row(&row)
		t: Trade
		if err := sql.row_scan_struct(&row, &t); err != nil {
			fmt.eprintfln("scan: %v", err)
			return
		}
		fmt.printfln("  #%v  %v  %v @ %.2f", t.id, t.symbol, t.qty, t.price)
	}

	// query + reflective struct scan (explicit scan_struct): column names matched
	// to struct field names. Reflection is opt-in — sql.scan() is positional-only;
	// scangen generates concrete scanners for annotated structs.
	fmt.println("\n--- all trades (reflective struct scan) ---")
	{
		rows, err := sql.query(db, "SELECT id, symbol, qty, price FROM trades ORDER BY id")
		if err != nil {
			fmt.eprintfln("query: %v", err)
			return
		}
		defer sql.rows_close(&rows)

		for sql.next(&rows) {
			t: Trade
			if serr := sql.scan_struct(&rows, &t); serr != nil {
				fmt.eprintfln("scan: %v", serr)
				return
			}
			fmt.printfln("  #%v  %-4v  %v @ %.2f", t.id, t.symbol, t.qty, t.price)
		}
		// next() returns false for both a clean end-of-rows and a mid-stream
		// failure, so check rows_err afterward (nil = fully consumed).
		if rerr := sql.rows_err(&rows); rerr != nil {
			fmt.eprintfln("rows: %v", rerr)
			return
		}
	}

	// An analytical aggregation, positionally scanned. notional = sum(qty*price).
	fmt.println("\n--- notional per symbol (positional scan) ---")
	{
		rows, err := sql.query(
			db,
			"SELECT symbol, sum(qty) AS shares, sum(qty * price) AS notional " +
			"FROM trades GROUP BY symbol HAVING sum(qty * price) >= ? ORDER BY notional DESC",
			f64(1000),
		)
		if err != nil {
			fmt.eprintfln("query: %v", err)
			return
		}
		defer sql.rows_close(&rows)

		for sql.next(&rows) {
			symbol: string
			shares: i64
			notional: f64
			if serr := sql.scan(&rows, &symbol, &shares, &notional); serr != nil {
				fmt.eprintfln("scan: %v", serr)
				return
			}
			fmt.printfln("  %-4v  %v shares  $%.2f", symbol, shares, notional)
		}
		if rerr := sql.rows_err(&rows); rerr != nil {
			fmt.eprintfln("rows: %v", rerr)
			return
		}
	}
}

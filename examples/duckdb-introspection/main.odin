package main


import "core:fmt"
import "database:drivers/duckdb"
import "database:sql"
import sb "database:sqlbuilder"


main :: proc() {
	db, err := sql.open(&duckdb.driver, "./examples/duckdb-introspection/Bayou_Teche.duckdb")
	if err != nil {
		fmt.eprintfln("open: %v", err)
		return
	}
	defer sql.close(db)
	b: sb.Builder
	sb.init(&b)
	defer sb.destroy(&b)
	sb.select(&b, Catchments.comid, Catchments.latitude, Catchments.longitude)
	sb.from(&b, Catchments)
	q, args := sb.to_query(&b)

	rows, qerr := sql.query(db, q, ..args)
	if qerr != nil {
		fmt.eprintfln("query: %v", qerr)
		return
	}
	defer sql.rows_close(&rows)

	for sql.next(&rows) {
		c: Catchment
		if serr := scan(&rows, &c); serr != nil {
			fmt.eprintfln("scan: %v", serr)
			return
		}
		fmt.printfln("  #%v  %v  %v", c.comid, c.latitude, c.longitude)
	}

	if rerr := sql.rows_err(&rows); rerr != nil {
		fmt.eprintfln("rows: %v", rerr)
		return
	}
	fmt.println("done")
}

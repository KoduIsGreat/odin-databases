// A real HTTP server backed by database:exec + database:exec/nbio + odin-http.
//
// This example needs laytan/odin-http, which is NOT vendored in this repo. Build
// it with a collection flag pointing at a local checkout, e.g.:
//
//   git clone https://github.com/laytan/odin-http /tmp/odin-http
//   odin run examples/http -collection:database=. -collection:http=/tmp/odin-http
//
// Then:
//   curl localhost:8080/users/1      -> {"id":1,"name":"Alice","age":30}
//   curl localhost:8080/users/999    -> 404
//   curl localhost:8080/slow         -> 504 after ~200ms (deadline + query cancel)
//
// The server runs multi-threaded (one nbio loop per core). A single shared
// executor serves all of them: each request's blocking query runs on a worker
// thread, and the response is written back on the loop thread that submitted it
// (the bridge routes the completion per-request, so it returns to the right
// loop). The executor needs no loop reference.
package http_example

import "core:fmt"
import "core:log"
import "core:strconv"
import "core:time"

import http "http:odin-http"

import "database:exec"
import xn "database:exec/nbio"
import sql "database:sql"
import sqlite "database:drivers/sqlite"

DB_PATH :: "/tmp/odin_http_example.db"

// Handlers can't capture, so the shared executor is a package global, set up in
// main before serving begins. No loop global is needed — submit binds each
// request to the loop of the thread handling it.
g_ex: ^exec.Executor

User :: struct {
	id:   i64,
	name: string,
	age:  int,
}

// --- GET /users/(%d+) : a DB-backed lookup with a deadline ---

Get_User_Job :: struct {
	using req: xn.Request,
	res:       ^http.Response,
	id:        i64,
	user:      User,
}

get_user_run :: proc(jb: ^exec.Job, conn: ^sql.Conn) {
	j := cast(^Get_User_Job)jb
	row := sql.query_row(conn, "SELECT id, name, age FROM users WHERE id = ?", j.id)
	defer sql.close_row(&row)
	j.err = sql.row_scan_struct(&row, &j.user) // No_Row surfaces here
}

get_user_finish :: proc(jb: ^exec.Job) {
	j := cast(^Get_User_Job)jb
	if j.responded {return}
	j.responded = true

	if j.err != nil {
		#partial switch e in j.err {
		case sql.General_Error:
			if e == .No_Row {
				j.res.status = .Not_Found
				http.respond(j.res)
				return
			}
		}
		log.errorf("get_user: %s", sql.err_to_string(j.err))
		j.res.status = .Internal_Server_Error
		http.respond(j.res)
		return
	}
	http.respond_json(j.res, j.user)
}

get_user_timeout :: proc(r: ^xn.Request) {
	j := cast(^Get_User_Job)r
	j.res.status = .Gateway_Timeout
	http.respond(j.res)
}

handle_get_user :: proc(req: ^http.Request, res: ^http.Response) {
	id, ok := strconv.parse_i64(req.url_params[0])
	if !ok {
		res.status = .Bad_Request
		http.respond(res)
		return
	}

	j := exec.new_job(g_ex, Get_User_Job)
	j.res = res
	j.id = id
	j.run = get_user_run
	j.finish = get_user_finish
	j.on_timeout = get_user_timeout

	if !xn.submit_db(g_ex, &j.req, 5 * time.Second) {
		res.status = .Service_Unavailable
		http.respond(res)
		exec.job_destroy(&j.job)
	}
}

// --- GET /slow : demonstrates the deadline (504) + cooperative cancellation ---

Slow_Job :: struct {
	using req: xn.Request,
	res:       ^http.Response,
}

slow_run :: proc(jb: ^exec.Job, conn: ^sql.Conn) {
	for _ in 0 ..< 100 { // ~1s of work, but cooperatively cancellable
		if exec.is_cancelled(jb) {return}
		time.sleep(10 * time.Millisecond)
	}
}

slow_finish :: proc(jb: ^exec.Job) {
	j := cast(^Slow_Job)jb
	if j.responded {return}
	j.responded = true
	http.respond_plain(j.res, "done")
}

slow_timeout :: proc(r: ^xn.Request) {
	j := cast(^Slow_Job)r
	j.res.status = .Gateway_Timeout
	http.respond(j.res)
}

handle_slow :: proc(req: ^http.Request, res: ^http.Response) {
	j := exec.new_job(g_ex, Slow_Job)
	j.res = res
	j.run = slow_run
	j.finish = slow_finish
	j.on_timeout = slow_timeout

	if !xn.submit_db(g_ex, &j.req, 200 * time.Millisecond) { // short deadline
		res.status = .Service_Unavailable
		http.respond(res)
		exec.job_destroy(&j.job)
	}
}

seed_db :: proc() {
	db, err := sql.open(&sqlite.driver, DB_PATH)
	if err != nil {
		fmt.eprintfln("seed open: %v", err)
		return
	}
	defer sql.close(db)
	sql.exec(db, "DROP TABLE IF EXISTS users")
	sql.exec(db, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
	sql.exec(db, "INSERT INTO users (id, name, age) VALUES (?, ?, ?)", i64(1), "Alice", i64(30))
	sql.exec(db, "INSERT INTO users (id, name, age) VALUES (?, ?, ?)", i64(2), "Bob", i64(25))
}

main :: proc() {
	context.logger = log.create_console_logger(.Info)

	seed_db()

	db, oerr := sql.open(&sqlite.driver, DB_PATH)
	if oerr != nil {
		fmt.eprintfln("open: %v", oerr)
		return
	}

	// One shared executor for every server loop; the completer is loop-agnostic.
	ex: exec.Executor
	exec.executor_init(&ex, db, 4, 4, 16, xn.completer()) // 4 DB workers, 4 IO, bg cap 16
	g_ex = &ex

	router: http.Router
	http.router_init(&router)
	http.route_get(&router, "/users/(%d+)", http.handler(handle_get_user))
	http.route_get(&router, "/slow", http.handler(handle_slow))

	s: http.Server
	http.server_shutdown_on_interrupt(&s)

	// Default opts run one nbio loop per core; the bridge routes each completion
	// back to the loop that submitted it.
	fmt.println("listening on http://localhost:8080")
	err := http.listen_and_serve(&s, http.router_handler(&router))
	fmt.printfln("server stopped: %v", err)

	// Graceful: let in-flight queries finish (up to 5s) before closing the DB.
	exec.executor_shutdown(&ex, 5 * time.Second)
}

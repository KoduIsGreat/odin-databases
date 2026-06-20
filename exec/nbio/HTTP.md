# Driving an HTTP server with `database:exec/nbio`

This is the **handler layer** (phase 2b) that sits on top of the `exec_nbio`
bridge. The bridge itself (`bridge.odin`) is built and tested against real
`core:nbio` in `bridge_test.odin`; everything in *this* document is
**illustrative** — it depends on a third-party HTTP library
([`laytan/odin-http`](https://github.com/laytan/odin-http)) that is not vendored
here, so it is not compiled or tested by this repo. Treat the `http.*` calls as
indicative of shape, not a verified API.

## What is verified vs. illustrative

| Piece | Status |
|---|---|
| Worker pool, pinned connections, lanes, bounded background, cancellation (`database:exec`) | built + tested |
| Cross-thread completion delivery onto the loop thread (`exec_nbio.completer`) | built + tested against `core:nbio` |
| Per-request deadline → 504 + query interrupt + drop-late-result (`exec_nbio.submit` + `on_timeout`) | built + tested |
| The `http.*` handler bodies below (router, `respond_json`, `respond`) | illustrative only |

## The shape

Each request becomes a job that embeds `exec_nbio.Request`. `run` does the
blocking database work on a worker; `finish` writes the response on the loop
thread; `on_timeout` writes a 504 on the loop thread if the deadline fires
first. The bridge guarantees `finish` and `on_timeout` both run on the loop
thread and that exactly one of them produces a response (the `responded` guard).

```odin
package server

import "core:nbio"
import "core:time"

import http "shared:odin-http"   // ILLUSTRATIVE import path — not vendored here

import "database:exec"
import sql "database:sql"
import sqlite "database:drivers/sqlite"
import xn "database:exec/nbio"

User :: struct { id: i64, name: string, age: int }

// A handler job: embed exec_nbio.Request first, then the HTTP response handle
// and the typed result.
Get_User_Job :: struct {
	using req: xn.Request,
	res:       ^http.Response, // parked until finish/on_timeout
	user:      User,
	found:     bool,
}

// run: WORKER thread. Plain blocking sql on the worker's pinned connection.
get_user_run :: proc(jb: ^exec.Job, conn: ^sql.Conn) {
	j := cast(^Get_User_Job)jb
	row := sql.query_row(conn, "SELECT id, name, age FROM users WHERE id = ?", j.user.id)
	defer sql.close_row(&row)
	if e := sql.row_scan_struct(&row, &j.user); e != nil {
		j.err = e                          // No_Row surfaces here
		return
	}
	j.found = true
}

// finish: LOOP thread. Write the normal response — but honour `responded`, since
// a deadline may already have answered with 504.
get_user_finish :: proc(jb: ^exec.Job) {
	j := cast(^Get_User_Job)jb
	if j.responded { return }              // the deadline already replied
	j.responded = true

	if j.err != nil {
		respond_sql_error(j.res, j.err)    // No_Row -> 404, pool timeout -> 503, ...
		return
	}
	http.respond_json(j.res, j.user)
}

// on_timeout: LOOP thread. The deadline fired before run finished; the bridge has
// already set `responded` and interrupted the query. Just send the 504.
get_user_timeout :: proc(r: ^xn.Request) {
	j := cast(^Get_User_Job)r
	http.respond(j.res, .Gateway_Timeout)
}

// The HTTP handler: parse inputs, build the job, submit with a deadline, return.
// The loop keeps serving other connections while the worker runs the query.
handle_get_user :: proc(ex: ^exec.Executor, loop: ^nbio.Event_Loop,
                        req: ^http.Request, res: ^http.Response) {
	id, ok := parse_i64(req.url_params["id"]) // illustrative param access
	if !ok {
		http.respond(res, .Bad_Request)
		return
	}

	j := exec.new_job(ex, Get_User_Job)
	j.loop       = loop
	j.res        = res
	j.user.id    = id
	j.run        = get_user_run
	j.finish     = get_user_finish
	j.on_timeout = get_user_timeout

	if !xn.submit_db(ex, &j.req, 5 * time.Second) {  // 5s deadline
		http.respond(res, .Service_Unavailable)      // executor draining
		exec.job_destroy(&j.job)                     // we still own it
	}
}

// Map sql errors to status codes. Log the rich (query-annotated) text; never
// put it in the response body.
respond_sql_error :: proc(res: ^http.Response, err: sql.Error) {
	#partial switch e in err {
	case sql.General_Error:
		switch e {
		case .No_Row:                        http.respond(res, .Not_Found)
		case .Pool_Timeout, .Pool_Exhausted: http.respond(res, .Service_Unavailable)
		case .Pool_Closed:                   http.respond(res, .Internal_Server_Error)
		}
	case:
		http.respond(res, .Internal_Server_Error)
	}
}
```

## Wiring it up

```odin
main :: proc() {
	nbio.acquire_thread_event_loop()
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	db, _ := sql.open(&sqlite.driver, "app.db")
	sql.set_conn_wait_timeout(db, 2 * time.Second) // pool saturation -> Pool_Timeout -> 503

	ex: exec.Executor
	exec.executor_init(&ex, db, 8, 32, 64, xn.completer(loop)) // 8 DB, 32 IO, bg cap 64
	defer exec.executor_shutdown(&ex)

	// router.get(&r, "/users/:id", proc(req, res) { handle_get_user(&ex, loop, req, res) })
	// http.listen_and_serve(&server, router.handler(&r))  // drives nbio.tick internally
}
```

## Open items before this is real

1. **odin-http is not vendored here.** Vendor it and replace the illustrative
   `http.*` calls with the real API.
2. **nbio generation.** odin-http historically bundled its own, older `nbio`
   with a different API than `core:nbio` (which this bridge targets). Confirm the
   odin-http you use runs on `core:nbio` — if it bundles the older one, the
   bridge needs porting to that API (the `exec`/`wake_up`/`prep_*` calls differ).
3. **The drain hook / who calls `tick`.** odin-http's server runs the nbio loop
   for you. Confirm its loop is `core:nbio`'s so the worker's `wake_up` actually
   breaks the server's `tick` — otherwise the completion op won't be picked up
   promptly. (`bridge_test.odin` drives `nbio.tick` itself to prove the path; a
   real server would rely on its own loop.)
4. **Per-worker connection + SQLite.** With pinned connections a `:memory:` DSN
   gives each worker its own empty database; use a file DSN in a real server.

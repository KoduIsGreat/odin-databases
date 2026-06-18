package main

import "core:fmt"
import "database:dburl"
import "database:sql"

import "testcontainers:docker"
import pg "testcontainers:modules/postgres"


seed :: proc(db: ^sql.DB) -> sql.Error {
	sql.exec(
		db,
		"CREATE TABLE IF NOT EXISTS users (id SERIAL PRIMARY KEY, name TEXT NOT NULL)",
	) or_return
	sql.exec(db, "INSERT INTO users (name) VALUES ('Alice')") or_return
	sql.exec(db, "INSERT INTO users (name) VALUES ('Bob')") or_return
	return nil
}

User :: struct {
	id:   int,
	name: string,
}

get_users :: proc(db: ^sql.DB) -> ([dynamic]User, sql.Error) {
	users := make([dynamic]User, context.allocator)
	rows, err := sql.query(db, "SELECT * FROM users")
	if err != nil {
		fmt.eprintln("Error querying")
		return users, err
	}
	defer sql.rows_close(&rows)

	for sql.next(&rows) {
		user: User
		if err := sql.scan(&rows, &user.id, &user.name); err != nil {
			return nil, err
		}
		append(&users, user)
	}

	if rerr := sql.rows_err(&rows); rerr != nil {
		return users, rerr
	}
	return users, nil
}

main :: proc() {
	client := docker.make_client()
	fmt.println("starting postgres...")
	p, ok := pg.start(client)
	if !ok {
		fmt.eprintln("Failed to start postgres")
		return
	}
	defer pg.stop(&p)
	port, _ := docker.mapped_port(p, "5432/tcp")

	if ready := docker.wait_until_ready(p); !ready {
		fmt.eprintln("Failed to wait for postgres")
		return
	}

	conn_str := pg.connection_string(p)
	fmt.println("postgres ready !")

	db, err := dburl.open_url(conn_str)
	if err != nil {
		fmt.printfln("could not connect: %v", dburl.error_to_string(err))
		return
	}
	defer sql.close(db)
	seed(db)
	fmt.println("database seeded.")
	users, uerr := get_users(db)
	if uerr != nil {
		fmt.printfln("users err %v: ", sql.err_to_string(uerr))
		return
	}

	for u in users {
		fmt.printfln("user %v", u)
	}
}

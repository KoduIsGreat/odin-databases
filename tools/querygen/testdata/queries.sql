-- Example query file for querygen. Generate against a schema with:
--   users(id INTEGER, name TEXT, email TEXT, age INTEGER)

-- name: GetUserByID :one
-- arg: id i64
SELECT id, name, email FROM users WHERE id = ?;

-- name: ListUsersByAge :many
-- arg: min_age i64
SELECT id, name FROM users WHERE age >= ? ORDER BY name;

-- name: CreateUser :exec
-- arg: name string
-- arg: email string
-- arg: age i64
INSERT INTO users (name, email, age) VALUES (?, ?, ?);

-- name: DeleteUser :exec
-- arg: id i64
DELETE FROM users WHERE id = ?;

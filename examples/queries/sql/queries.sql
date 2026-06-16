-- Annotated queries for the querygen example. Each `-- name:` header names the
-- generated proc and its cardinality; `-- arg:` lines name the `?` placeholders
-- (and declare their Odin types). Regenerate queries.gen.odin with
-- `just gen-queries` after editing this file.

-- name: CreateUser :exec
-- arg: name string
-- arg: email string
-- arg: age i64
INSERT INTO users (name, email, age) VALUES (?, ?, ?);

-- name: GetUserByID :one
-- arg: id i64
SELECT id, name, email, age FROM users WHERE id = ?;

-- name: ListUsersByMinAge :many
-- arg: min_age i64
SELECT id, name, age FROM users WHERE age >= ? ORDER BY name;

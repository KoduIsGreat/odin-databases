-- Source schema for the `introspected` example.
--
-- schema.gen.odin (row structs + sqlbuilder descriptors) is generated FROM a
-- database built from this file — the database is the source of truth. To
-- regenerate after editing this file:
--
--   just gen-introspection
--
-- which builds a throwaway SQLite DB from this DDL and runs schemagen's DB
-- front-end against it.

CREATE TABLE users (
  id         INTEGER PRIMARY KEY,
  name       TEXT NOT NULL,
  email      VARCHAR(255),
  age        INTEGER,
  rating     REAL,
  avatar     BLOB,
  created_at DATETIME
);

CREATE TABLE posts (
  id           INTEGER PRIMARY KEY,
  user_id      INTEGER,
  title        TEXT,
  published_at TIMESTAMP
);

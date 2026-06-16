-- Schema for the querygen example. querygen describes each query in
-- queries.sql against a throwaway database built from this file (see the
-- `just gen-queries` recipe), so the inferred result types match these columns.
CREATE TABLE users (
    id    INTEGER PRIMARY KEY,
    name  TEXT NOT NULL,
    email TEXT,
    age   INTEGER
);

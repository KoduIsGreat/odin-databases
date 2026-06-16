# Examples

Focused, runnable examples for odin-databases. Each is its own package.

| Example | What it covers | Run |
|---|---|---|
| [`quickstart`](quickstart) | The core `database:sql` API with the SQLite driver: `open`, `exec`, transactions + prepared statements, `query_row`, and reflective/positional `scan`. No codegen. | `just run-example quickstart` |
| [`query_builder`](query_builder) | The typed `sqlbuilder` driven by generated descriptors — `select`/`where`/`order_by`, a typed `join`, typed `insert` via `bind`, `update`/`delete`. Also shows **scangen** + **schemagen (struct mode)** on annotated structs. | `just run-example query_builder` |
| [`introspection`](introspection) | **schemagen (DB mode)**: generate row structs + descriptors by introspecting a real database (`schema.sql`). Shows nullable columns → `Maybe(T)` and concrete scanners. | `just run-example introspection` |
| [`queries`](queries) | **querygen**: generate typed data-access procs from annotated `.sql` (`sql/queries.sql`). Result types are *described* against the schema; `:one`/`:many`/`:exec` cardinalities. | `just run-example queries` |
| [`migrations`](migrations) | Schema migrations with the **`database:migrate`** runner: load `.sql` files with `from_dir`, `up`/`down`/`status`, timestamp-versioned, reversible. | `just run-example migrations` |
| [`testing`](testing) | Testing database code with the **mock driver** — no real database needed. | `just test-example testing` |

## Code generation

Several examples use generated code, which is committed so the examples compile
out of the box. Regenerate after editing a struct, `schema.sql`, or query file:

```sh
just gen-query-builder    # scangen + schemagen (struct mode) on query_builder
just gen-introspection    # schemagen DB mode + scangen on introspection
just gen-queries          # querygen on the queries example
just gen-all              # everything, including the repo root
```

- **scangen** turns a `//+sql:scan` struct into a concrete `scan_<T>` proc
  (`scan.gen.odin`).
- **schemagen** turns a `//+sql:table` struct *or* a live database into typed
  `Column(T)` descriptors (`schema.gen.odin`); in DB mode it also emits the row
  structs.
- **querygen** turns annotated `.sql` queries into typed data-access procs
  (`queries.gen.odin`), describing result types against a schema-loaded DB.

See [`../DESIGN.md`](../DESIGN.md) for the design rationale behind each layer.

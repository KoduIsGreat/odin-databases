package sql

// Re-exports of the driver-contract types so user code can continue using
// `sql.Driver`, `sql.Conn_Handle`, etc. The actual definitions live in
// `database/sql/driver` so concrete drivers can depend on a small,
// stable contract package without pulling in the user-facing API.

import drv "./driver"

Driver :: drv.Driver
Conn_Handle :: drv.Conn_Handle
Stmt_Handle :: drv.Stmt_Handle
Rows_Handle :: drv.Rows_Handle
Tx_Handle :: drv.Tx_Handle

package sql

// Re-exports of the driver-contract value/error types. See `database:driver`
// for definitions and rationale.

import drv "database:driver"

Value :: drv.Value
Null :: drv.Null
Result :: drv.Result
Column :: drv.Column
Tx_Options :: drv.Tx_Options
Isolation_Level :: drv.Isolation_Level

Error :: drv.Error
Error_Ctx :: drv.Error_Ctx
Driver_Error :: drv.Driver_Error
// Pool_Error :: drv.Pool_Error
General_Error :: drv.General_Error
Arg_Error :: drv.Arg_Error
Arg_Error_Kind :: drv.Arg_Error_Kind
Scan_Error :: drv.Scan_Error
Scan_Error_Kind :: drv.Scan_Error_Kind
Custom_Value :: drv.Custom_Value

error_is_no_row :: drv.error_is_no_row
err_to_string :: drv.err_to_string
error_ctx :: drv.error_ctx
error_query :: drv.error_query

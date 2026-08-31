/* Independent filelist entry for the BRAM adapter regression.  The protocol
 * checker is intentionally shared with the legacy contract test so that the
 * traffic/value comparison is byte-for-byte identical; this filelist never
 * compiles the original RTL implementation. */
`include "sim/tb_ds_persistent_feed_contract.v"

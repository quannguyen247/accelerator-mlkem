# Out-of-context implementation on 7-series parts (added by
# scripts/create_project.tcl for xc7* parts, implementation only).
# Clock source: a global buffer site, so clock delay and skew are timed.
set_property HD.CLK_SRC BUFGCTRL_X0Y16 [get_ports aclk]
# Partition pins of the other ports: a small region at the centre of the
# device, so every port net is routed to a pin (no Route 35-198) without
# pulling the logic apart (a range over the whole device did).
set_property HD.PARTPIN_RANGE {SLICE_X60Y110:SLICE_X100Y140} [get_ports -filter {NAME != aclk}]
# Vectorless power: resets are released (the default activity holds them).
set_switching_activity -deassert_resets

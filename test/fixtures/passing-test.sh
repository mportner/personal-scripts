#
# File:    passing-test.sh
# Created: 2026-08-29
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# A test file that parses and asserts nothing, used by run_test.sh as the
# control against its unparseable twin: the runner must still report this one as
# passing. Under fixtures/ so the runner's own glob never picks it up.

assert_equals ok ok "the control fixture passes"

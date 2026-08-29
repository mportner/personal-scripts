#
# File:    unparseable-test.sh
# Created: 2026-08-29
# License: MIT
#
# Copyright (c) 2026 Michael Portner
#
# A test file that does not parse, used by run_test.sh to check that the runner
# reports such a file as failed rather than passed. It is under fixtures/ rather
# than beside the real tests so the runner's own glob never picks it up, and it
# is not linted for the same reason it exists.

TEST_FAILURES=0

if [[ 1 == 1 ; then
  echo "this file is never reached"
fi

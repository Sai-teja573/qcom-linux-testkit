#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Robustly find and source init_env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INIT_ENV=""
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"
        break
    fi
    SEARCH=$(dirname "$SEARCH")
done

if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi

# Only source if not already loaded (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="adsp_remoteproc"
firmware_name="adsp"
res_file="./$TESTNAME.res"
LOG_FILE="./$TESTNAME.log"

exec > >(tee -a "$LOG_FILE") 2>&1

test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="
log_info "Get the firmware output and find the position of adsp"

if validate_remoteproc_running "$firmware_name" "$LOG_FILE"; then
    log_pass "$firmware_name remoteproc validated as running"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "$firmware_name remoteproc failed validation"
    echo "$TESTNAME FAIL" > "$res_file"
fi
# At this point we are sure: path exists and is in running state
rproc_path=$(get_remoteproc_path_by_firmware "$firmware_name")


stop_remoteproc "$rproc_path" || {
    log_fail "$TESTNAME" "stop failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
}
log_pass "adsp stop successful"

log_info "Restarting remoteproc"
start_remoteproc "$rproc_path" || {
    log_fail "$TESTNAME" "start failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
}

echo "adsp PASS"
log_pass "adsp PASS"
echo "$TESTNAME PASS" > "$res_file"
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
exit 0

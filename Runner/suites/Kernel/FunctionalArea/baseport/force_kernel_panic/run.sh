#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc.
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

if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="force_kernel_panic"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"
marker_file="./last_test_status"
autorun_script="./auto_panic_result_check.sh"
service_file="/etc/systemd/system/auto-panic-check.service"
log_out="./service_output.log"
log_err="./service_error.log"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

log_info "Creating post-reboot result checker script..."
cat << 'EOF' > "$autorun_script"
#!/bin/sh

TESTNAME="force_kernel_panic"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
res_file="$SCRIPT_DIR/$TESTNAME.res"
marker_file="$SCRIPT_DIR/last_test_status"
service_file="/etc/systemd/system/auto-panic-check.service"

sleep 5
clear

if [ -f "$marker_file" ] && grep -q "PANIC_TRIGGERED" "$marker_file"; then
    echo "$TESTNAME PASS" > "$res_file"
    echo -e "\n=== $TESTNAME Result ==="
    cat "$res_file"
    echo -e "\n=== $TESTNAME Result ===" > /dev/tty1
    cat "$res_file" > /dev/tty1
    rm -f "$marker_file"
else
    echo "$TESTNAME FAIL" > "$res_file"
    echo -e "\n[ERROR] Marker file missing or corrupted." > /dev/tty1
fi

# Cleanup
systemctl disable auto-panic-check.service
rm -f "$service_file"
systemctl daemon-reexec

# Prevent shell prompt
exec /bin/login
EOF

chmod +x "$autorun_script"

log_info "Creating systemd service for post-reboot result check..."
cat << EOF > "$service_file"
[Unit]
Description=Auto Panic Reboot Test Checker
After=multi-user.target

[Service]
Type=simple
ExecStart=$test_path/auto_panic_result_check.sh
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
Restart=no

[Install]
WantedBy=multi-user.target
EOF

if [ $? -eq 0 ]; then
    log_info "Created systemd service file: $service_file"
else
    log_fail "Failed to create systemd service file!"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

systemctl daemon-reexec
log_info "Systemd daemon reloaded."

systemctl disable getty@tty1.service
systemctl enable auto-panic-check.service
if [ $? -eq 0 ]; then
    log_info "Service enabled at boot."
else
    log_fail "Failed to enable service!"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

log_info "Writing marker file before triggering panic..."
echo "PANIC_TRIGGERED" > "$marker_file"
sync

log_info "Setting kernel to auto-reboot after panic in 5 seconds..."
echo 5 > /proc/sys/kernel/panic

log_info "Triggering kernel panic now..."
echo c > /proc/sysrq-trigger

# This line will never be reached
exit 1

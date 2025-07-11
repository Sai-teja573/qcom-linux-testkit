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

# Only source if not already loaded
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# Always source functestlib.sh
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="UFS_Validation"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "--------------------------------------------------"
log_info "------------- Starting $TESTNAME Test ------------"

check_dependencies dd grep cut head tail udevadm

# --- Kernel Config Checks ---
MANDATORY_CONFIGS="CONFIG_SCSI_UFSHCD CONFIG_SCSI_UFS_QCOM"
OPTIONAL_CONFIGS="CONFIG_SCSI_UFSHCD_PLATFORM CONFIG_SCSI_UFSHCD_PCI CONFIG_SCSI_UFS_CDNS_PLATFORM CONFIG_SCSI_UFS_HISI CONFIG_SCSI_UFS_EXYNOS CONFIG_SCSI_UFS_ROCKCHIP CONFIG_SCSI_UFS_BSG"

log_info "Checking mandatory kernel configs for UFS..."
if ! check_kernel_config "$MANDATORY_CONFIGS" 2>/dev/null; then
    log_skip "Missing one or more mandatory UFS kernel configs: $MANDATORY_CONFIGS"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

log_info "Checking optional kernel configs for UFS..."
missing_optional=""
for cfg in $OPTIONAL_CONFIGS; do
    if ! check_kernel_config "$cfg" 2>/dev/null; then
        log_info "[OPTIONAL] $cfg is not enabled"
        missing_optional="$missing_optional $cfg"
    fi
done
[ -n "$missing_optional" ] && log_info "Optional configs not present but continuing:$missing_optional"

# --- Device Tree Check ---
check_dt_nodes "/sys/bus/platform/devices/*ufs*" || {
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
}

# --- UFS Block Detection ---
detect_ufs_partition_block() {
    if command -v lsblk >/dev/null 2>&1 && command -v udevadm >/dev/null 2>&1; then
        for part in $(lsblk -lnpo NAME,TYPE | awk '$2 == "part" {print $1}'); do
            if udevadm info --query=all --name="$part" 2>/dev/null | grep -qi "ufs"; then
                echo "$part"
                return 0
            fi
        done
    fi

    for part in /dev/sd[a-z][0-9]*; do
        [ -e "$part" ] || continue
        if command -v udevadm >/dev/null 2>&1 &&
           udevadm info --query=all --name="$part" 2>/dev/null | grep -qi "ufs"; then
            echo "$part"
            return 0
        fi
    done

    return 1
}

block_dev=$(detect_ufs_partition_block)
if [ -z "$block_dev" ]; then
    log_skip "No UFS block device found."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

log_info "Detected UFS block: $block_dev"

# --- RootFS Detection ---
if command -v findmnt >/dev/null 2>&1; then
    rootfs_dev=$(findmnt -n -o SOURCE /)
else
    log_warn "findmnt not available, using fallback rootfs detection"
    rootfs_dev=$(awk '$2 == "/" { print $1 }' /proc/mounts)
fi

resolved_block=$(readlink -f "$block_dev" 2>/dev/null)
resolved_rootfs=$(readlink -f "$rootfs_dev" 2>/dev/null)

# --- Read Test (check if 'iflag=direct' supported) ---
log_info "Running basic read test on $block_dev (non-rootfs)..."

# Test for iflag=direct support
if echo | dd of=/dev/null iflag=direct 2>/dev/null; then
    DD_CMD="dd if=$block_dev of=/dev/null bs=1M count=32 iflag=direct"
else
    log_warn "'iflag=direct' not supported by dd. Falling back to standard dd."
    DD_CMD="dd if=$block_dev of=/dev/null bs=1M count=32"
fi

if $DD_CMD >/dev/null 2>&1; then
    log_pass "UFS read test succeeded"
else
    log_fail "UFS read test failed"
    log_info "Try manually: $DD_CMD"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

# --- I/O Stress Test ---
log_info "Running I/O stress test (64MB read+write on tmpfile)..."
tmpfile="$test_path/ufs_test.img"

# Prepare dd write command
if echo | dd of=/dev/null conv=fsync 2>/dev/null; then
    DD_WRITE="dd if=/dev/zero of=$tmpfile bs=1M count=64 conv=fsync"
else
    log_warn "'conv=fsync' not supported by dd. Using basic write."
    DD_WRITE="dd if=/dev/zero of=$tmpfile bs=1M count=64"
fi

# Use simplified dd read for BusyBox compatibility
if $DD_WRITE >/dev/null 2>&1 &&
   dd if="$tmpfile" of=/dev/null bs=1M count=64 >/dev/null 2>&1; then
    log_pass "UFS I/O stress test passed"
    rm -f "$tmpfile"
else
    log_fail "UFS I/O stress test failed"
    df -h . | sed 's/^/[INFO] /'
    ls -lh "$test_path"/ufs_test.img | sed 's/^/[INFO] /'
    rm -f "$tmpfile"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
# --- Dmesg Errors ---
scan_dmesg_errors "ufs" "$test_path"

log_pass "$TESTNAME completed successfully"
echo "$TESTNAME PASS" > "$res_file"
exit 0

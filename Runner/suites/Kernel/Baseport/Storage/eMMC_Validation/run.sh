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

TESTNAME="eMMC_Validation"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "--------------------------------------------------"
log_info "------------ Starting $TESTNAME Test -------------"

check_dependencies dd grep cut head tail udevadm

# --- Kernel Config Checks ---
MANDATORY_CONFIGS="CONFIG_MMC CONFIG_MMC_BLOCK"
OPTIONAL_CONFIGS="CONFIG_MMC_SDHCI CONFIG_MMC_SDHCI_MSM CONFIG_MMC_BLOCK_MINORS"

missing_optional=""
log_info "Checking mandatory kernel configs for eMMC..."
if ! check_kernel_config "$MANDATORY_CONFIGS" 2>/dev/null; then
    log_skip "Missing one or more mandatory eMMC kernel configs: $MANDATORY_CONFIGS"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

log_info "Checking optional kernel configs for eMMC..."
for cfg in $OPTIONAL_CONFIGS; do
    if ! check_kernel_config "$cfg" 2>/dev/null; then
        log_info "[OPTIONAL] $cfg is not enabled"
        missing_optional="$missing_optional $cfg"
    fi
done

if [ -n "$missing_optional" ]; then
    log_info "Optional configs not present but continuing:$missing_optional"
fi

# --- Device Tree and Block Device Check ---
check_dt_nodes "/sys/bus/mmc/devices/*mmc*" || {
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
}

block_dev=$(detect_emmc_partition_block)
if [ -z "$block_dev" ]; then
    log_skip "No eMMC block device found."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

log_info "Detected eMMC block: $block_dev"

# --- RootFS check fallback if findmnt is missing ---
rootfs_dev="unknown"
if command -v findmnt >/dev/null 2>&1; then
    rootfs_dev=$(findmnt -n -o SOURCE /)
else
    log_warn "findmnt not available, using fallback rootfs detection"
    rootfs_dev=$(awk '$2 == "/" { print $1 }' /proc/mounts)
fi

# --- Prevent direct read from rootfs ---
if [ "$block_dev" = "$rootfs_dev" ]; then
    log_warn "eMMC block $block_dev is mounted as rootfs. Skipping direct read test."
else
    log_info "Running basic read test on $block_dev (non-rootfs)..."
    if dd if="$block_dev" of=/dev/null bs=1M count=32 iflag=direct status=none 2>/dev/null; then
        log_pass "eMMC read test succeeded"
    else
        log_warn "'iflag=direct' not supported by dd. Falling back to standard dd."
        if dd if="$block_dev" of=/dev/null bs=1M count=32 status=none 2>/dev/null; then
            log_pass "eMMC read test succeeded (fallback)"
        else
            log_fail "eMMC read test failed"
            echo "$TESTNAME FAIL" > "$res_file"
            exit 1
        fi
    fi
fi

# --- I/O Stress Test ---
log_info "Running I/O stress test (64MB read+write on tmpfile)..."
tmpfile="$test_path/emmc_test.img"

if dd if=/dev/zero of="$tmpfile" bs=1M count=64 conv=fsync status=none 2>/dev/null; then
    if dd if="$tmpfile" of=/dev/null bs=1M status=none 2>/dev/null; then
        log_pass "eMMC I/O stress test passed"
        rm -f "$tmpfile"
    else
        log_fail "eMMC I/O stress test failed (read)"
        rm -f "$tmpfile"
        echo "$TESTNAME FAIL" > "$res_file"
        exit 1
    fi
else
    log_warn "'conv=fsync' not supported by dd. Using basic write fallback."
    if dd if=/dev/zero of="$tmpfile" bs=1M count=64 status=none 2>/dev/null &&
       dd if="$tmpfile" of=/dev/null bs=1M status=none 2>/dev/null; then
        log_pass "eMMC I/O stress test passed (fallback)"
        rm -f "$tmpfile"
    else
        log_fail "eMMC I/O stress test failed (fallback)"
        rm -f "$tmpfile"
        echo "$TESTNAME FAIL" > "$res_file"
        exit 1
    fi
fi

# --- Dmesg Scan ---
scan_dmesg_errors "mmc" "$test_path"

log_pass "$TESTNAME completed successfully"
echo "$TESTNAME PASS" > "$res_file"
exit 0

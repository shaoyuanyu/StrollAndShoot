#!/usr/bin/env bash
set -euo pipefail

# Pull app log from phone sandbox to local file
SDK_ROOT="${HMOS_SDK_ROOT:-$HOME/.hmos/command-line-tools}"
HDC="$SDK_ROOT/sdk/default/openharmony/toolchains/hdc"
BUNDLE="io.github.shaoyuanyu.strollandshoot"
SANDBOX="/data/app/el2/100/base/${BUNDLE}/haps/entry/files/app_log.txt"
OUTPUT="${1:-./app_log_$(date +%Y%m%d_%H%M%S).txt}"

DEVICE=$("$HDC" list targets 2>/dev/null | head -1)
if [ -z "$DEVICE" ]; then
    echo "No device found. Connect phone and try again."
    exit 1
fi

echo "Pulling log from $DEVICE..."
"$HDC" -t "$DEVICE" file recv "$SANDBOX" "$OUTPUT"
echo "Saved to: $OUTPUT"
head -30 "$OUTPUT"

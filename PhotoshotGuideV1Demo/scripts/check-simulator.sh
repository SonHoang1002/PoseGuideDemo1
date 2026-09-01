#!/bin/bash
# Check for a booted simulator. If none is available, tell the user to boot one.
# Output format:
#   [STATUS] BOOTED | NO_SIMULATOR
#   [DEVICE] iPhone 17 (iOS 27.0)
#   [UDID] D696F193-FF6D-4D58-BD1E-30CE439EA8D5

set -e

# Find a booted simulator.
BOOTED_LINE=$(xcrun simctl list devices booted 2>/dev/null | grep -E "Booted" | head -1 || true)

if [ -z "$BOOTED_LINE" ]; then
    echo "[STATUS] NO_SIMULATOR"
    echo ""
    echo "No booted simulator was found."
    echo ""
    echo "Available simulators:"
    echo ""
    # List iPhone and iPad devices only, excluding watchOS and tvOS.
    xcrun simctl list devices available 2>/dev/null | grep -E "^\s+(iPhone|iPad)" | grep -v "unavailable" | head -10
    echo ""
    echo "Open the Simulator app, boot a device, and try again."
    exit 0
fi

# Parse the device name and UDID.
# Format: "    iPhone 17 (D696F193-FF6D-4D58-BD1E-30CE439EA8D5) (Booted)"
# The UDID is a 36-character UUID (hexadecimal characters and dashes), unlike the "Booted" text.
UDID=$(echo "$BOOTED_LINE" | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}' | head -1)
# Use awk to extract the portion before the UDID as the device name.
# Also trim a trailing "(" and whitespace when present.
DEVICE_NAME=$(echo "$BOOTED_LINE" | awk -F"($UDID)" '{print $1}' | sed -E 's/[[:space:]]+\($//' | xargs)

# Get the iOS version.
IOS_VERSION=$(xcrun simctl list devices booted 2>/dev/null | grep -B1 "$UDID" | grep -oE "iOS [0-9.]+" | head -1 || echo "iOS unknown")

echo "[STATUS] BOOTED"
echo "[DEVICE] $DEVICE_NAME ($IOS_VERSION)"
echo "[UDID] $UDID"

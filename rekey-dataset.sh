#!/bin/bash
#
# rekey-dataset.sh — Destroy and recreate a ZFS dataset with a new keyfile
#
# Usage:
#   ./rekey-dataset.sh <dataset> <new-keyfile>
#
# Example:
#   ./rekey-dataset.sh pool/mydata /root/key/newkey
#

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <dataset> <new-keyfile>"
    exit 1
fi

DATASET="$1"
NEW_KEY="$2"

if [[ $EUID -ne 0 ]]; then
    echo "Must run as root"
    exit 1
fi

if ! zfs list "$DATASET" >/dev/null 2>&1; then
    echo "Dataset does not exist: $DATASET"
    exit 1
fi

if [[ ! -f "$NEW_KEY" ]]; then
    echo "Keyfile does not exist: $NEW_KEY"
    exit 1
fi

# ─── Capture current properties ──────────────────────────────────────

echo "Reading properties from $DATASET..."
echo ""

ENCRYPTION=$(zfs get -H -o value encryption "$DATASET")
KEYFORMAT=$(zfs get -H -o value keyformat "$DATASET")
COMPRESSION=$(zfs get -H -o value compression "$DATASET")
ATIME=$(zfs get -H -o value atime "$DATASET")
MOUNTPOINT=$(zfs get -H -o value mountpoint "$DATASET")
CANMOUNT=$(zfs get -H -o value canmount "$DATASET")

echo "  encryption   = $ENCRYPTION"
echo "  keyformat    = $KEYFORMAT"
echo "  compression  = $COMPRESSION"
echo "  atime        = $ATIME"
echo "  mountpoint   = $MOUNTPOINT"
echo "  canmount     = $CANMOUNT"
echo "  new keyfile  = $NEW_KEY"
echo ""

if [[ "$ENCRYPTION" == "off" ]]; then
    echo "Dataset is not encrypted. Nothing to rekey."
    exit 1
fi

# ─── Confirm ─────────────────────────────────────────────────────────

echo "WARNING: This will destroy $DATASET and ALL its snapshots."
echo "All data in the dataset will be lost."
echo ""
read -r -p "Type the dataset name to confirm: " confirm
if [[ "$confirm" != "$DATASET" ]]; then
    echo "Aborted."
    exit 1
fi

# ─── Destroy and recreate ────────────────────────────────────────────

echo ""
echo "Destroying $DATASET..."
zfs destroy -r "$DATASET"

echo "Creating $DATASET with new keyfile..."
zfs create \
    -o encryption="$ENCRYPTION" \
    -o keyformat="$KEYFORMAT" \
    -o keylocation="file://$NEW_KEY" \
    -o compression="$COMPRESSION" \
    -o atime="$ATIME" \
    -o mountpoint="$MOUNTPOINT" \
    -o canmount="$CANMOUNT" \
    "$DATASET"

echo ""
echo "Done. New dataset created with keyfile: $NEW_KEY"
zfs get encryption,keyformat,keylocation,compression,atime,mountpoint,canmount "$DATASET"

#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# make-sample-zip.sh
#
# Creates a tiny placeholder zip used as the "build artifact" in the
# reproduction pipelines. Linux equivalent of make-sample-zip.ps1.
#
# Usage:
#   scripts/make-sample-zip.sh <version> <out-dir>
#
# Example:
#   scripts/make-sample-zip.sh 3.4.1 /tmp/out
#
# Produces: <out-dir>/rcm-operations-<version>.zip
# -----------------------------------------------------------------------------
set -euo pipefail

VERSION="${1:-3.4.1}"
OUT_DIR="${2:-./out}"

mkdir -p "$OUT_DIR"

STAGE="$OUT_DIR/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"

cat > "$STAGE/README.txt" <<EOF
rcm-operations $VERSION
Generated for the JFrog build-promotion silent-success reproduction.
This file is meant to be uploaded to <source-repo>/rcm-operations/ via
the JFrog Generic Artifacts task, then promoted to <target-repo>.
EOF

ZIP_PATH="$OUT_DIR/rcm-operations-$VERSION.zip"
rm -f "$ZIP_PATH"

# Use zip if available, otherwise fall back to python's zipfile module
if command -v zip >/dev/null 2>&1; then
    (cd "$STAGE" && zip -q -r "$ZIP_PATH" .)
elif command -v python3 >/dev/null 2>&1; then
    python3 - "$ZIP_PATH" "$STAGE" <<'PY'
import os, sys, zipfile
zip_path, stage = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(stage):
        for f in files:
            full = os.path.join(root, f)
            arc  = os.path.relpath(full, stage)
            z.write(full, arc)
PY
else
    echo "ERROR: neither 'zip' nor 'python3' is available on this agent." >&2
    exit 1
fi

echo "Created $ZIP_PATH"
ls -l "$ZIP_PATH"

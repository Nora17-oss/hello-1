#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build --product StorageSmoke
BIN_DIR="$(swift build --show-bin-path)"
BASE="$(mktemp -d "$PWD/.build/persistence-XXXXXX")"
ROOT="$BASE/case"
"$BIN_DIR/StorageSmoke" init "$ROOT"
"$BIN_DIR/StorageSmoke" resume "$ROOT"
"$BIN_DIR/StorageSmoke" verify "$ROOT"
printf '\nPersistence evidence: %s\n' "$ROOT"

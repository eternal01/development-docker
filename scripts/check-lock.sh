#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
LOCK_FILE="${1:-${ROOT_DIR}/.env.lock}"
[ -f "${LOCK_FILE}" ] || { echo "Lock file not found: ${LOCK_FILE}" >&2; exit 1; }
TMP_FILE="$(mktemp)"
trap 'rm -f "${TMP_FILE}" "${TMP_FILE}.normalized"' EXIT

bash "${ROOT_DIR}/scripts/lock-versions.sh" "${TMP_FILE}" >/dev/null
# The first line is generation metadata, not part of the resolved-input check.
tail -n +2 "${TMP_FILE}" > "${TMP_FILE}.normalized"
tail -n +2 "${LOCK_FILE}" > "${TMP_FILE}.expected"
trap 'rm -f "${TMP_FILE}" "${TMP_FILE}.normalized" "${TMP_FILE}.expected"' EXIT
if diff -u "${TMP_FILE}.expected" "${TMP_FILE}.normalized"; then
    echo "Compose inputs match ${LOCK_FILE}."
else
    echo "Compose inputs differ from ${LOCK_FILE}; review changes and run 'make lock' to update." >&2
    exit 1
fi

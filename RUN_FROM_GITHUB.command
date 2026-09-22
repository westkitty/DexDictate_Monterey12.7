#!/bin/bash
# Bootstrap the current GitHub repository, then run its one-command probe.

set -u
set -o pipefail

readonly REPOSITORY="westkitty/DexDictate_Monterey12.7"
readonly ARCHIVE_URL="https://github.com/${REPOSITORY}/archive/refs/heads/main.tar.gz"

BOOTSTRAP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/DexDictateMonterey12.7.XXXXXX")" || {
    printf 'BLOCKED_SETUP: could not create a temporary download directory.\n' >&2
    exit 20
}
ARCHIVE_PATH="${BOOTSTRAP_DIR}/probe.tar.gz"

printf '%s\n' 'Downloading the current DexDictate Monterey Whisper Probe from GitHub...'
if ! curl --fail --location --show-error --retry 2 \
    --output "$ARCHIVE_PATH" \
    "${ARCHIVE_URL}?cachebust=$(date +%s)-$$"; then
    printf 'BLOCKED_SETUP: GitHub archive download failed.\n' >&2
    exit 20
fi

if ! tar -xzf "$ARCHIVE_PATH" -C "$BOOTSTRAP_DIR"; then
    printf 'BLOCKED_SETUP: downloaded archive could not be extracted.\n' >&2
    exit 20
fi

SOURCE_DIR="$(find "$BOOTSTRAP_DIR" -mindepth 1 -maxdepth 1 -type d -name 'DexDictate_Monterey12.7-*' -print -quit)"
if [ -z "$SOURCE_DIR" ] || [ ! -f "$SOURCE_DIR/RUN_MONTEREY_PROBE.command" ]; then
    printf 'BLOCKED_SETUP: GitHub archive did not contain RUN_MONTEREY_PROBE.command.\n' >&2
    exit 20
fi

exec /bin/bash "$SOURCE_DIR/RUN_MONTEREY_PROBE.command" "$@"

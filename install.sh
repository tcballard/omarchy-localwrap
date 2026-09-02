#!/usr/bin/env bash
# Install the LocalWrap Omarchy plugin from this repository checkout into the
# user-owned Omarchy plugin directory. A complete verified payload is staged
# beside the destination and atomically swapped, with rollback on interruption.
#
# Usage:
#   ./install.sh [--force]
#
# --force replaces an existing installed copy of this plugin.

set -euo pipefail

PLUGIN_ID="io.github.tcballard.localwrap"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${HOME}/.config/omarchy/plugins/${PLUGIN_ID}"
PAYLOAD=(manifest.json BarWidget.qml Panel.qml Model.js localwrap-helper README.md LICENSE)
TARGET_PARENT="$(dirname "$TARGET_DIR")"
STAGING_DIR=""
BACKUP_DIR=""
SWAP_COMPLETE=0

cleanup() {
  local status=$?
  if [[ "$SWAP_COMPLETE" -ne 1 && -n "$BACKUP_DIR" && -d "$BACKUP_DIR" && ! -e "$TARGET_DIR" ]]; then
    mv -- "$BACKUP_DIR" "$TARGET_DIR"
  fi
  if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
    rm -rf -- "$STAGING_DIR"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

FORCE=0
for argument in "$@"; do
  case "$argument" in
    --force) FORCE=1 ;;
    *)
      echo "Unknown argument: $argument" >&2
      echo "Usage: ./install.sh [--force]" >&2
      exit 2
      ;;
  esac
done

declare -A SEEN=()
for file in "${PAYLOAD[@]}"; do
  if [[ -n "${SEEN[$file]:-}" ]]; then
    echo "Duplicate payload path: ${file}" >&2
    exit 1
  fi
  SEEN[$file]=1
  if [[ ! -f "${SOURCE_DIR}/${file}" || -L "${SOURCE_DIR}/${file}" ]]; then
    echo "Missing ${file} next to install.sh — run from a complete checkout." >&2
    exit 1
  fi
done

if [[ -e "$TARGET_DIR" ]]; then
  if [[ -L "$TARGET_DIR" || ! -d "$TARGET_DIR" ]]; then
    echo "Refusing destination collision at ${TARGET_DIR}: expected a real directory." >&2
    exit 1
  fi
  if [[ ! -f "$TARGET_DIR/manifest.json" ]] ||
      ! grep -Eq '"id"[[:space:]]*:[[:space:]]*"io.github.tcballard.localwrap"' "$TARGET_DIR/manifest.json"; then
    echo "Refusing to replace a directory not owned by ${PLUGIN_ID}." >&2
    exit 1
  fi
  if [[ "$FORCE" -ne 1 ]]; then
    echo "Already installed at ${TARGET_DIR}" >&2
    echo "Re-run with --force to replace it." >&2
    exit 1
  fi
fi

mkdir -p "$TARGET_PARENT"
STAGING_DIR="$(mktemp -d "${TARGET_PARENT}/.${PLUGIN_ID}.stage.XXXXXX")"
for file in "${PAYLOAD[@]}"; do
  cp --no-preserve=ownership,timestamps -- "${SOURCE_DIR}/${file}" "${STAGING_DIR}/${file}"
  if [[ "$(sha256sum "${SOURCE_DIR}/${file}" | cut -d' ' -f1)" != \
        "$(sha256sum "${STAGING_DIR}/${file}" | cut -d' ' -f1)" ]]; then
    echo "Verification failed while staging ${file}." >&2
    exit 1
  fi
done
chmod 0755 "${STAGING_DIR}/localwrap-helper"
chmod 0644 "${STAGING_DIR}/manifest.json" "${STAGING_DIR}/BarWidget.qml" \
  "${STAGING_DIR}/Panel.qml" "${STAGING_DIR}/Model.js" \
  "${STAGING_DIR}/README.md" "${STAGING_DIR}/LICENSE"

if [[ -e "$TARGET_DIR" ]]; then
  BACKUP_DIR="${TARGET_PARENT}/.${PLUGIN_ID}.rollback.$$"
  if [[ -e "$BACKUP_DIR" ]]; then
    echo "Refusing rollback-path collision at ${BACKUP_DIR}." >&2
    exit 1
  fi
  mv -- "$TARGET_DIR" "$BACKUP_DIR"
fi
mv -- "$STAGING_DIR" "$TARGET_DIR"
STAGING_DIR=""
SWAP_COMPLETE=1
if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
  rm -rf -- "$BACKUP_DIR"
  BACKUP_DIR=""
fi

echo "Installed ${PLUGIN_ID} to ${TARGET_DIR}"
echo
echo "Next steps:"
echo "  omarchy plugin validate \"${TARGET_DIR}\""
echo "  qmllint -I \"\$OMARCHY_PATH/shell\" \"${TARGET_DIR}/BarWidget.qml\" \"${TARGET_DIR}/Panel.qml\""
echo "  omarchy-shell shell rescanPlugins"
echo "  omarchy plugin list --json   # confirm the plugin is discovered, then enable it"
echo
echo "Open LocalWrap from the bar and add a repository in the panel."

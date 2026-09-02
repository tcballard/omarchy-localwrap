#!/usr/bin/env bash
# Install the LocalWrap Omarchy plugin from this repository checkout into the
# user-owned Omarchy plugin directory. A complete verified payload is staged
# beside the destination and committed by the helper's locked, descriptor-
# relative renameat2 transaction.
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

cleanup() {
  local status=$?
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

ensure_owned_directory() {
  local path="$1"
  if [[ -e "$path" ]]; then
    if [[ -L "$path" || ! -d "$path" || ! -O "$path" ]]; then
      echo "Refusing installation ancestor ${path}: expected a real user-owned directory." >&2
      exit 1
    fi
  else
    mkdir -- "$path"
    if [[ -L "$path" || ! -d "$path" || ! -O "$path" ]]; then
      echo "Could not create a real user-owned installation ancestor at ${path}." >&2
      exit 1
    fi
  fi
}

ensure_owned_directory "$HOME"
ensure_owned_directory "$HOME/.config"
ensure_owned_directory "$HOME/.config/omarchy"
ensure_owned_directory "$TARGET_PARENT"
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

swap_result="$("${SOURCE_DIR}/localwrap-helper" install-swap "$STAGING_DIR" "$TARGET_DIR" "$FORCE")"
STAGING_DIR=""
if [[ "$swap_result" != *'"backup":null'* ]]; then
  echo "Warning: the verified install succeeded, but a displaced backup was retained for inspection." >&2
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

#!/usr/bin/env bash
# Install the LocalWrap Omarchy plugin from this repository checkout into the
# user-owned Omarchy plugin directory. Copies files only (Omarchy forbids
# symlinks inside plugin folders) and never enables or starts anything itself.
#
# Usage:
#   ./install.sh [--force]
#
# --force replaces an existing installed copy of this plugin.

set -euo pipefail

PLUGIN_ID="io.github.tcballard.localwrap"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${HOME}/.config/omarchy/plugins/${PLUGIN_ID}"
PAYLOAD=(manifest.json BarWidget.qml Panel.qml Model.js README.md LICENSE)

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

for file in "${PAYLOAD[@]}"; do
  if [[ ! -f "${SOURCE_DIR}/${file}" ]]; then
    echo "Missing ${file} next to install.sh — run from a complete checkout." >&2
    exit 1
  fi
done

if [[ -e "$TARGET_DIR" ]]; then
  if [[ "$FORCE" -ne 1 ]]; then
    echo "Already installed at ${TARGET_DIR}" >&2
    echo "Re-run with --force to replace it." >&2
    exit 1
  fi
  rm -rf "$TARGET_DIR"
fi

mkdir -p "$TARGET_DIR"
for file in "${PAYLOAD[@]}"; do
  cp "${SOURCE_DIR}/${file}" "${TARGET_DIR}/${file}"
done

echo "Installed ${PLUGIN_ID} to ${TARGET_DIR}"
echo
echo "Next steps:"
echo "  omarchy plugin validate \"${TARGET_DIR}\""
echo "  qmllint -I \"\$OMARCHY_PATH/shell\" \"${TARGET_DIR}/BarWidget.qml\" \"${TARGET_DIR}/Panel.qml\""
echo "  omarchy-shell shell rescanPlugins"
echo "  omarchy plugin list --json   # confirm the plugin is discovered, then enable it"
echo
echo "Configure repositories in ~/.config/localwrap/repositories.json — see README.md."

#!/usr/bin/env bash
# install.sh — install codex-switch into ~/.local/bin and ensure it is on PATH.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SRC_DIR/codex-switch"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
DEST="$BIN_DIR/codex-switch"

[ -f "$SRC" ] || { echo "error: $SRC not found" >&2; exit 1; }

mkdir -p "$BIN_DIR"
install -m 755 "$SRC" "$DEST"
echo "installed: $DEST"

# Ensure ~/.local/bin is on PATH (append to the right rc file, once).
case ":$PATH:" in
  *":$BIN_DIR:"*) echo "PATH already includes $BIN_DIR" ;;
  *)
    rc="$HOME/.bashrc"
    [ -n "${ZSH_VERSION:-}" ] && rc="$HOME/.zshrc"
    line="export PATH=\"$BIN_DIR:\$PATH\""
    if ! grep -qsF "$line" "$rc"; then
      printf '\n# added by codex-switch install.sh\n%s\n' "$line" >> "$rc"
      echo "added $BIN_DIR to PATH in $rc — run: source $rc"
    fi
    ;;
esac

echo
echo "next steps:"
echo "  codex-switch init          # set up ~/.codex/config.toml"
echo "  codex-switch add <name>    # add your first relay profile"
echo "  codex-switch <name>        # switch to it"

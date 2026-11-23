#!/bin/bash
# Usage: ./install.sh [PREFIX]   (default ~/.local)  -- same as `make install`
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
exec make install PREFIX="${1:-$HOME/.local}"

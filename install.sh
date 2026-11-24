#!/bin/bash
# Install sjob.
#   ./install.sh [PREFIX]              install (default PREFIX: ~/.local)
#   ./install.sh --uninstall [PREFIX]  remove it again
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

action=install
if [[ ${1:-} == --uninstall ]]; then action=uninstall; shift; fi
prefix=${1:-$HOME/.local}

case $action in
install)
    mkdir -p "$prefix/share/sjob" "$prefix/bin"
    rm -rf "$prefix/share/sjob/bin" "$prefix/share/sjob/lib" "$prefix/share/sjob/etc"
    cp -r bin lib etc "$prefix/share/sjob/"
    ln -sf "$prefix/share/sjob/bin/sjob" "$prefix/bin/sjob"
    echo "installed: $prefix/bin/sjob"
    case ":$PATH:" in *":$prefix/bin:"*) ;; *) echo "note: $prefix/bin is not on your PATH" ;; esac
    ;;
uninstall)
    rm -rf "$prefix/share/sjob" "$prefix/bin/sjob"
    echo "removed sjob from $prefix"
    ;;
esac

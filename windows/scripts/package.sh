#!/bin/bash
# Builds the Windows release: a portable .exe and a per-user installer.
# Needs: rustup with the x86_64-pc-windows-gnu target, mingw-w64 (for the
# linker and windres), and NSIS (makensis). Output goes to ../dist.
set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="$HOME/.cargo/bin:$PATH"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)"

cargo build --release --target x86_64-pc-windows-gnu
EXE="target/x86_64-pc-windows-gnu/release/tendedero.exe"

DIST="$(pwd)/../dist"
mkdir -p "$DIST"
cp "$EXE" "$DIST/Tendedero-${VERSION}-portable.exe"
makensis -V2 -DVERSION="$VERSION" -DDIST="$DIST" installer/tendedero.nsi >/dev/null
echo "Built:"
ls -la "$DIST"/Tendedero-*

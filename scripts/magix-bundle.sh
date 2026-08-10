#!/usr/bin/env bash
# Create and run standalone bundles of Magix-built scripts (Linux only).
#
# Assumptions
# -----------
# A Linux host with the GNU toolchain: ldd, readlink, shasum, and patchelf are
# required (the latter is preinstalled on GitHub's Ubuntu runners), running on
# x86_64 or aarch64. The host's glibc must be at least as new as the one the
# binary was built against, so the dynamically linked glibc symbols resolve;
# glibc is therefore not bundled.
#
# Usage
# -----
#   magix-bundle.sh bundle <script-file>
#   magix-bundle.sh run <script-file> [args...]
#   magix-bundle.sh run blog.hs -j4 --color --digest build
#
# Prerequisites
# -------------
# 'bundle' needs the script to be built by Magix first, e.g. by running
# ./blog.hs once. 'run' needs the bundle to already exist (created by
# 'bundle').
#
# Motivation
# ----------
# A fresh CI runner has neither the Nix store nor Magix's cache, so every push
# would rebuild the whole toolchain. Keeping a compact bundle in the CI cache
# lets later runs skip Nix and Magix entirely.
#
# Problem
# -------
# Magix compiles the script into a binary. GHC statically links all Haskell
# libraries into it, but a few C libraries (e.g. zlib, gmp, ffi) remain
# dynamically linked. The build result is a symlink into the Nix store, living
# in Magix's cache (resolved the same way Magix resolves it: $MAGIX_CACHE_DIR,
# else $XDG_CACHE_HOME/magix, else ~/.cache/magix). Copying that symlink is
# useless on a fresh runner, and the full store closure is far too large to
# cache.
#
# Solution
# --------
# Copy the binary and the transitive closure of the Nix-store C libraries it
# links against into a bundle keyed by a SHA-256 of the script contents, and
# rewrite the library search paths with `patchelf --set-rpath`: the binary to
# '$ORIGIN/lib' and each bundled library to '$ORIGIN', so the loader finds
# them at run time without LD_LIBRARY_PATH or the Nix store. glibc and other
# system libraries are deliberately not bundled, since their versions must
# match the host's; the loader resolves them from the system search path.
#
# Implementation
# --------------
# 'bundle' resolves Magix's cache directory, picks the newest result symlink
# for the script (skipping dangling ones) or fails with a clear error,
# dereferences it to the Nix store path, copies the binary, and recursively
# copies the transitive closure of its Nix-store C library dependencies,
# rewriting each copied library's rpath to '$ORIGIN'. 'run' computes the same
# SHA-256, checks the bundle exists, and execs the binary, passing through any
# arguments. The bundle lives at $MAGIX_BUNDLE_DIR/<sha256 of script>/bin/<name>
# with the C libraries in lib/; MAGIX_BUNDLE_DIR defaults to ~/.cache/magix-bundles.
#
# Note
# ----
# Nixpkgs binaries also carry an interpreter (PT_INTERP) pointing into the Nix
# store, so 'bundle' must additionally reset it with `patchelf --set-interpreter
# /lib64/ld-linux-x86-64.so.2` (aarch64: /lib/ld-linux-aarch64.so.1) to the
# host's loader, otherwise the bundle cannot exec on a machine without the Nix
# store. This is why the host glibc must be at least as new as the build-time
# one (see Assumptions): the bundled libs resolve their glibc symbols against
# the host's glibc.
#
# When overriding MAGIX_BUNDLE_DIR, e.g. in CI, the persistent cache (such as
# the actions/cache path in the workflow) must point to the same location,
# otherwise 'run' cannot find bundles stored by 'bundle' on a previous run.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: magix-bundle.sh <bundle|run> <script-file> [args...]" >&2
  exit 1
fi
CMD="$1"
shift
SCRIPT_FILE="$1"
shift

[ -f "$SCRIPT_FILE" ] || {
  echo "error: script not found: $SCRIPT_FILE" >&2
  exit 1
}

NAME=$(basename "$SCRIPT_FILE")
NAME=${NAME%.*}
HASH=$(sha256sum "$SCRIPT_FILE" | awk '{print $1}')
MAGIX_CACHE="${MAGIX_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/magix}"
DEST="${MAGIX_BUNDLE_DIR:-$HOME/.cache/magix-bundles}/$HASH"

# Copy the transitive closure of the binary's Nix-store C library
# dependencies into the bundle. System libraries (glibc and friends) are
# never bundled: they must resolve against the host's, so they are skipped
# here and found by the loader from the system search path at run time.
copy_lib_deps() {
  local src="$1"
  local deps dep base
  deps=$(ldd "$src" | awk '/\/nix\/store\//{print $3}')
  for dep in $deps; do
    case "$dep" in
      */*-glibc-*/*) continue ;;
    esac
    [ -e "$dep" ] || {
      echo "error: dependency '$dep' of '$src' not found" >&2
      exit 1
    }
    base=$(basename "$dep")
    if [ ! -f "$DEST/lib/$base" ]; then
      cp -L "$dep" "$DEST/lib/$base"
      copy_lib_deps "$dep"
    fi
  done
}

bundle() {
  mkdir -p "$DEST/bin" "$DEST/lib"

  RESULT=""
  for f in "$MAGIX_CACHE/"*"-$NAME-result"; do
    [ -L "$f" ] || continue
    [ -e "$f" ] || continue
    if [ -z "$RESULT" ] || [ "$f" -nt "$RESULT" ]; then
      RESULT="$f"
    fi
  done
  [ -n "$RESULT" ] || {
    echo "error: no build result for '$SCRIPT_FILE' found in $MAGIX_CACHE; run magix on the script first" >&2
    exit 1
  }
  RESULT=$(readlink -f "$RESULT")
  BIN="$RESULT/bin/.$NAME-wrapped"
  cp "$BIN" "$DEST/bin/$NAME"
  chmod +w "$DEST/bin/$NAME"

  copy_lib_deps "$BIN"

  case "$(uname -m)" in
    x86_64)
      INTERPRETER=/lib64/ld-linux-x86-64.so.2
      ;;
    aarch64)
      INTERPRETER=/lib/ld-linux-aarch64.so.1
      ;;
    *)
      echo "error: unsupported architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac

  patchelf \
    --set-interpreter "$INTERPRETER" \
    --set-rpath "\$ORIGIN/lib" \
    "$DEST/bin/$NAME"
  for lib in "$DEST"/lib/*; do
    [ -f "$lib" ] || continue
    chmod +w "$lib"
    patchelf --set-rpath "\$ORIGIN" "$lib"
  done
  echo "bundle created at $DEST"
}

run() {
  local binary="$DEST/bin/$NAME"
  if [ ! -f "$binary" ] || [ ! -d "$DEST/lib" ]; then
    echo "error: no bundle for '$SCRIPT_FILE' at $DEST; run 'magix-bundle.sh bundle $SCRIPT_FILE' first" >&2
    exit 1
  fi
  exec "$binary" "$@"
}

case "$CMD" in
  bundle)
    if [ "$#" -gt 0 ]; then
      echo "error: 'bundle' takes no extra arguments" >&2
      exit 1
    fi
    bundle
    ;;
  run) run "$@" ;;
  *)
    echo "error: unknown command '$CMD' (expected 'bundle' or 'run')" >&2
    exit 1
    ;;
esac

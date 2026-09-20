#!/bin/sh
## Build (and optionally publish) the hex package from a clean export of
## HEAD. rebar3 cannot lock a `_checkouts` app, and rebar3_hex writes the
## package requirements from the lock, so a package built in a tree with
## `_checkouts/livery` silently drops livery (and h2) from its
## requirements. Exporting HEAD leaves `_checkouts` behind.
##
## Usage: scripts/hex_package.sh [build|publish] [rebar3 hex publish args]
## e.g. `scripts/hex_package.sh publish --replace` to overwrite a version
## published less than an hour ago.
set -eu

MODE="${1:-build}"
[ $# -gt 0 ] && shift
REQUIRED="gpb h2 livery"

ROOT="$(git rev-parse --show-toplevel)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
    echo "error: uncommitted changes; the package is built from HEAD" >&2
    exit 1
fi

git -C "$ROOT" archive HEAD | tar -x -C "$WORK"
cd "$WORK"

rebar3 hex build

VSN="$(sed -n 's/.*{vsn, "\(.*\)"}.*/\1/p' src/livery_grpc.app.src)"
TARBALL="_build/default/lib/livery_grpc/hex/livery_grpc-$VSN.tar"
tar -xf "$TARBALL" -C "$WORK" metadata.config

for DEP in $REQUIRED; do
    if ! grep -q "{<<\"app\">>,<<\"$DEP\">>}" metadata.config; then
        echo "error: $DEP is missing from the package requirements" >&2
        exit 1
    fi
done
echo "livery_grpc $VSN requirements ok: $REQUIRED"

if [ "$MODE" = "publish" ]; then
    rebar3 hex publish "$@"
fi

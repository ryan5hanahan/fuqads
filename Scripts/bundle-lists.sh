#!/bin/sh
# bl0cksh1t — pin + pre-convert the default filter lists (FR-4, NFR-3).
#
#   Scripts/bundle-lists.sh             # snapshot (reuse if present) + bundle
#   Scripts/bundle-lists.sh --refresh   # force re-download of snapshots
#   Scripts/bundle-lists.sh --offline   # never download; fail if snapshots missing
#
# Snapshot files live in lists-snapshots/ and are committed — they are the
# pinned inputs of the build, so installed blocking works identically
# without any network access (FR-4).
set -eu
cd "$(dirname "$0")/.."

CLI="swift run --package-path BlockerCore blocker-cli"
mode="normal"
for arg in "$@"; do
    case "$arg" in
        --refresh) mode="refresh" ;;
        --offline) mode="offline" ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

case "$mode" in
    refresh)
        $CLI snapshot --out .
        ;;
    normal)
        if ls lists-snapshots/*.txt >/dev/null 2>&1; then
            echo "snapshots present (use --refresh to re-download)" >&2
        else
            $CLI snapshot --out .
        fi
        ;;
    offline)
        ls lists-snapshots/*.txt >/dev/null 2>&1 || {
            echo "error: lists-snapshots/ missing; run without --offline" >&2
            exit 1
        }
        ;;
esac

$CLI bundle --out .
echo "done — regenerate the Xcode project and rebuild to pick up new rules" >&2

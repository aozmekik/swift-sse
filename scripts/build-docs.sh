#!/usr/bin/env bash
# Builds the DocC catalogs of SSE and SSELLM with warnings treated as errors.
#
#   scripts/build-docs.sh [output-directory]
#
# Requires macOS with Xcode (for `xcrun docc`). Symbol graphs are extracted with a separate,
# fresh scratch path (a cached build would not emit them), so the regular build cache is kept.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$root/.build/docs}"
scratch="$root/.build/docs-scratch"
graphs="$scratch/symbol-graphs"

rm -rf "$scratch" "$output"
mkdir -p "$graphs" "$output"

swift build \
    --package-path "$root" \
    --scratch-path "$scratch" \
    --target SSELLM \
    -Xswiftc -emit-symbol-graph \
    -Xswiftc -emit-symbol-graph-dir -Xswiftc "$graphs"

for module in SSE SSELLM; do
    mkdir -p "$graphs/$module"
    find "$graphs" -maxdepth 1 \( -name "$module.symbols.json" -o -name "$module@*.symbols.json" \) \
        -exec mv {} "$graphs/$module/" \;
    xcrun docc convert "$root/Sources/$module/$module.docc" \
        --additional-symbol-graph-dir "$graphs/$module" \
        --fallback-display-name "$module" \
        --fallback-bundle-identifier "tr.fergani.swift-sse.$module" \
        --output-path "$output/$module.doccarchive" \
        --warnings-as-errors
done

echo "Documentation archives written to $output"

#!/usr/bin/env bash
# Refresh the vendored Llama runtime (llama/) from the sibling llama.lua project.
set -euo pipefail

project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
source="$project/../llama.lua"
for required in "llama2.lua" "models/stories260K.bin" "models/tok512.bin"; do
    [[ -f "$source/$required" ]] || { echo "Missing $source/$required. Restore the sibling llama.lua project first." >&2; exit 1; }
done

mkdir -p "$project/llama/models"
cp -f "$source/llama2.lua" "$project/llama/llama2.lua"
cp -f "$source/models/stories260K.bin" "$project/llama/models/stories260K.bin"
cp -f "$source/models/tok512.bin" "$project/llama/models/tok512.bin"

# Regenerate the llama/ entries in SHA256SUMS (whole file kept sorted by path).
{
    grep -v -E '^[0-9a-f]{64}  llama/' "$project/SHA256SUMS" || true
    (cd "$project" && sha256sum llama/llama2.lua llama/models/stories260K.bin llama/models/tok512.bin)
} | sort -k 2 > "$project/SHA256SUMS.tmp"
mv "$project/SHA256SUMS.tmp" "$project/SHA256SUMS"
echo "Refreshed llama/ from $source and regenerated its SHA256SUMS entries."

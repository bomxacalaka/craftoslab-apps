#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: $0 [--profile PATH]" >&2; }
find_profile() {
    local root candidate
    for root in "$HOME/curseforge/minecraft/Instances" "$HOME/Documents/curseforge/minecraft/Instances" "$HOME/.local/share/curseforge/minecraft/Instances"; do
        [[ -d "$root" ]] || continue
        for candidate in "$root"/*; do
            [[ -d "$candidate" ]] || continue
            [[ "${candidate##*/}" == [Cc][Rr][Aa][Ff][Tt][Oo][Ss] ]] && { printf '%s\n' "$candidate"; return; }
        done
    done
    return 1
}

profile=""
while (($#)); do
    case "$1" in
        --profile|-p) (($# >= 2)) || { usage; exit 2; }; profile=$2; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done
[[ -n "$profile" ]] || profile=$(find_profile) || {
    echo "CurseForge profile 'CraftOS' was not found. Pass --profile with the instance directory." >&2; exit 1;
}
[[ -d "$profile" ]] || { echo "Minecraft profile not found: $profile" >&2; exit 1; }
profile=$(cd "$profile" && pwd -P)
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
llama_project=$(cd "$project/../llama.lua" && pwd -P)
[[ -f "$project/model/letters.bin" ]] || { echo "Missing model/letters.bin. Train or restore the model first." >&2; exit 1; }
[[ -f "$project/model/digits.bin" ]] || { echo "Missing model/digits.bin. Train or restore the model first." >&2; exit 1; }
[[ -f "$llama_project/llama2.lua" ]] || { echo "Missing sibling llama.lua/llama2.lua." >&2; exit 1; }
[[ -f "$llama_project/models/stories260K.bin" ]] || { echo "Missing Llama stories260K model." >&2; exit 1; }
[[ -f "$llama_project/models/tok512.bin" ]] || { echo "Missing Llama tokenizer." >&2; exit 1; }
apps="$profile/cc-apps/apps"
destination="$apps/draw-ocr"
staging="$apps/.draw-ocr-staging-$$"
backup="$apps/.draw-ocr-backup-$$"
legacy_data="$profile/cc-programs/programs/draw-ocr/data"

cleanup() { rm -rf -- "$staging"; }
trap cleanup EXIT
mkdir -p "$staging/model" "$staging/llama/models"
cp -f "$project/ocr.lua" "$staging/ocr.lua"
cp -f "$project/model/letters.bin" "$staging/model/letters.bin"
cp -f "$project/model/digits.bin" "$staging/model/digits.bin"
cp -f "$llama_project/llama2.lua" "$staging/llama/llama2.lua"
cp -f "$llama_project/models/stories260K.bin" "$staging/llama/models/stories260K.bin"
cp -f "$llama_project/models/tok512.bin" "$staging/llama/models/tok512.bin"
cp -f "$project/cc-appstore.json" "$staging/app.json"
cp -f "$project/icon.png" "$staging/icon.png"
if [[ -d "$destination/data" ]]; then
    mv "$destination/data" "$staging/data"
elif [[ -d "$legacy_data" ]]; then
    mv "$legacy_data" "$staging/data"
    echo "Migrated Draw OCR data from the legacy cc-programs layout"
fi
if [[ -e "$destination" ]]; then mv "$destination" "$backup"; fi
if ! mv "$staging" "$destination"; then
    [[ ! -e "$backup" ]] || mv "$backup" "$destination"
    if [[ -d "$staging/data" && ! -e "$destination/data" ]]; then mv "$staging/data" "$destination/data"; fi
    exit 1
fi
[[ ! -e "$backup" ]] || rm -rf -- "$backup"
trap - EXIT
echo "Synced Draw OCR to $destination"

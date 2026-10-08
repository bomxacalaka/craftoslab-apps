#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 [--profile PATH]" >&2
    echo "Profile resolution: 1) --profile PATH, 2) CurseForge instance 'CraftOS', 3) ~/.minecraft" >&2
}
find_curseforge_profile() {
    local root candidate
    for root in "$HOME/curseforge/minecraft/Instances" "$HOME/Documents/curseforge/minecraft/Instances" "$HOME/.local/share/curseforge/minecraft/Instances"; do
        [[ -d "$root" ]] || continue
        for candidate in "$root"/*; do
            [[ -d "$candidate" ]] || continue
            [[ "${candidate##*/}" == [Cc][Rr][Aa][Ff][Tt][Oo][Ss] ]] && { printf '%s\n' "$candidate"; return 0; }
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
if [[ -z "$profile" ]]; then
    profile=$(find_curseforge_profile) || profile=""
fi
if [[ -z "$profile" ]]; then
    profile="$HOME/.minecraft"
fi
[[ -d "$profile" ]] || { echo "Minecraft profile not found: $profile" >&2; exit 1; }
profile=$(cd "$profile" && pwd -P)
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
apps="$profile/cc-apps/apps"
destination="$apps/media-helper"
staging="$apps/.media-helper-staging-$$"
backup="$apps/.media-helper-backup-$$"
legacy_data="$profile/cc-programs/programs/media-helper/data"

cleanup() { rm -rf -- "$staging"; }
trap cleanup EXIT
mkdir -p "$staging"
cp -f "$project/cc-appstore.json" "$staging/app.json"
cp -f "$project/icon.png" "$staging/icon.png"
if [[ -d "$destination/data" ]]; then
    mv "$destination/data" "$staging/data"
elif [[ -d "$legacy_data" ]]; then
    mv "$legacy_data" "$staging/data"
    echo "Migrated Media Helper data from the legacy cc-programs layout"
fi

if [[ -e "$destination" ]]; then mv "$destination" "$backup"; fi
if ! mv "$staging" "$destination"; then
    [[ ! -e "$backup" ]] || mv "$backup" "$destination"
    if [[ -d "$staging/data" && ! -e "$destination/data" ]]; then mv "$staging/data" "$destination/data"; fi
    exit 1
fi
[[ ! -e "$backup" ]] || rm -rf -- "$backup"
trap - EXIT
echo "Synced CC Media Helper to $destination"

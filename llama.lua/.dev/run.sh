#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: run.sh [options]
  --backend standard|accelerated  CraftOS-PC backend (default: standard)
  --executable PATH               Explicit CraftOS-PC console executable
  --steps N                       Token count, 1-512 (default: 256)
  --temperature N                 Sampling temperature, 0-2 (default: 1)
  --top-p N                       Top-p value, 0-1 (default: 0.9)
  --seed N                        Random seed (default: 1)
  --benchmark-runs N              Number of runs, 1-100 (default: 1)
  --prompt TEXT                   Optional prompt
EOF
}

die() { echo "$*" >&2; exit 1; }
is_number() { [[ $1 =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]; }
in_range() { awk -v value="$1" -v low="$2" -v high="$3" 'BEGIN { exit !(value >= low && value <= high) }'; }
lua_quote() {
    local value=${1//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\r'/\\r}
    value=${value//$'\n'/\\n}
    printf '"%s"' "$value"
}

backend=standard
executable=""
steps=256
temperature=1
top_p=0.9
seed=1
benchmark_runs=1
prompt=""
while (($#)); do
    case "$1" in
        --backend|--executable|--steps|--temperature|--top-p|--topp|--seed|--benchmark-runs|--prompt)
            (($# >= 2)) || { usage; exit 2; }
            option=$1
            value=$2
            case "$option" in
                --backend) backend=$value ;;
                --executable) executable=$value ;;
                --steps) steps=$value ;;
                --temperature) temperature=$value ;;
                --top-p|--topp) top_p=$value ;;
                --seed) seed=$value ;;
                --benchmark-runs) benchmark_runs=$value ;;
                --prompt) prompt=$value ;;
            esac
            shift 2
            ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

[[ "$backend" == standard || "$backend" == accelerated ]] || die "Backend must be standard or accelerated."
[[ "$steps" =~ ^[0-9]+$ ]] && in_range "$steps" 1 512 || die "Steps must be an integer from 1 to 512."
is_number "$temperature" && in_range "$temperature" 0 2 || die "Temperature must be from 0 to 2."
is_number "$top_p" && in_range "$top_p" 0 1 || die "Top-p must be from 0 to 1."
[[ "$seed" =~ ^-?[0-9]+$ ]] || die "Seed must be an integer."
[[ "$benchmark_runs" =~ ^[0-9]+$ ]] && in_range "$benchmark_runs" 1 100 || die "Benchmark runs must be an integer from 1 to 100."

project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
if [[ -z "$executable" ]]; then
    if [[ "$backend" == accelerated ]]; then
        executable="$project/tools/craftos-accelerated/CraftOS-PC_console"
    else
        for name in craftos-pc CraftOS-PC craftos; do
            if command -v "$name" >/dev/null 2>&1; then
                executable=$(command -v "$name")
                break
            fi
        done
    fi
fi
[[ -n "$executable" && -x "$executable" ]] || die "CraftOS executable not found. Install CraftOS-PC or pass --executable PATH."

data_directory="$project/.craftos-data"
[[ "$backend" == accelerated ]] && data_directory="$project/.craftos-jit-data"
computer_root="$data_directory/computer/0"
output_path="$computer_root/llama2-output.txt"
metrics_path="$computer_root/llama2-metrics.txt"
rm -f -- "$output_path" "$metrics_path"

arguments=(
    /lab/llama2.lua
    --steps "$steps"
    --temperature "$temperature"
    --topp "$top_p"
    --seed "$seed"
    --benchmark-runs "$benchmark_runs"
)
if [[ -n "$prompt" ]]; then
    prompt_hex=$(printf '%s' "$prompt" | od -An -v -tx1 | tr -d ' \n')
    arguments+=(--prompt-hex "$prompt_hex")
fi
arguments+=(--output /llama2-output.txt --metrics /llama2-metrics.txt --quiet)

lua_arguments=""
for argument in "${arguments[@]}"; do
    [[ -z "$lua_arguments" ]] || lua_arguments+=", "
    lua_arguments+=$(lua_quote "$argument")
done
lua_code="shell.run($lua_arguments); os.shutdown()"

"$executable" --headless --directory "$data_directory" --mount-ro "lab=$project" --exec "$lua_code"
[[ -f "$output_path" && -f "$metrics_path" ]] || die "CraftOS did not produce result files."
cat "$output_path"
echo '---'
cat "$metrics_path"

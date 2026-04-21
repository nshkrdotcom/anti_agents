#!/usr/bin/env bash
# AntiAgents local Gemma server profile.
#
# This is a repo-local variant of:
#   /home/home/p/g/n/temp/GEMMA/server2_high_perf.sh
#
# It keeps the same Gemma 4 26B MoE Q2 model, but changes server defaults for
# AntiAgents-style experiments:
#   - disable reasoning/thinking extraction so responses land in message.content
#   - use a smaller context than the original 65k because AntiAgents prompts are short
#   - keep OpenAI-compatible chat/completions endpoints on localhost
#   - optionally enable a server-wide JSON schema for strict SSoT burst output
#
# Environment overrides:
#   AA_GEMMA_DIR=/path/to/GEMMA
#   AA_GEMMA_HOST=127.0.0.1
#   AA_GEMMA_PORT=8080
#   AA_GEMMA_CTX=16384
#   AA_GEMMA_PARALLEL=4
#   AA_GEMMA_JSON_SCHEMA=1
#   AA_GEMMA_SCHEMA_FILE=/path/to/schema.json
#   AA_GEMMA_EXTRA_ARGS="..."

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEMMA_DIR="${AA_GEMMA_DIR:-/home/home/p/g/n/temp/GEMMA}"
LLAMA_SERVER="${AA_LLAMA_SERVER:-$GEMMA_DIR/llama.cpp/build/bin/llama-server}"

MODEL_FILE="${AA_GEMMA_MODEL_FILE:-gemma-4-26B-A4B-it-UD-Q2_K_XL.gguf}"
MODEL_DIR="${AA_GEMMA_MODEL_DIR:-$GEMMA_DIR/models}"
MODEL="$MODEL_DIR/$MODEL_FILE"
URL="${AA_GEMMA_MODEL_URL:-https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/$MODEL_FILE}"

HOST="${AA_GEMMA_HOST:-127.0.0.1}"
PORT="${AA_GEMMA_PORT:-8080}"
CTX="${AA_GEMMA_CTX:-16384}"
PARALLEL="${AA_GEMMA_PARALLEL:-4}"
SCHEMA_FILE="${AA_GEMMA_SCHEMA_FILE:-$ROOT_DIR/scripts/gemma/anti_agents_burst_schema.json}"

if [ ! -x "$LLAMA_SERVER" ]; then
  echo "llama-server not found or not executable: $LLAMA_SERVER" >&2
  echo "Set AA_GEMMA_DIR or AA_LLAMA_SERVER to the local llama.cpp server path." >&2
  exit 1
fi

mkdir -p "$MODEL_DIR"

if [ ! -f "$MODEL" ]; then
  echo "Downloading Gemma 4 26B MoE UD-Q2_K_XL (~10.5GB) to $MODEL..."
  wget -c "$URL" -O "$MODEL"
fi

ARGS=(
  -m "$MODEL"
  -c "$CTX"
  -ngl 99
  -fit off
  --parallel "$PARALLEL"
  --host "$HOST"
  --port "$PORT"
  --reasoning off
  --reasoning-format none
  --reasoning-budget 0
  --skip-chat-parsing
)

if [ "${AA_GEMMA_JSON_SCHEMA:-0}" = "1" ]; then
  ARGS+=(--json-schema-file "$SCHEMA_FILE")
fi

if [ -n "${AA_GEMMA_EXTRA_ARGS:-}" ]; then
  # shellcheck disable=SC2206
  EXTRA_ARGS=($AA_GEMMA_EXTRA_ARGS)
  ARGS+=("${EXTRA_ARGS[@]}")
fi

echo "Starting Gemma 4 26B MoE Server for AntiAgents..."
echo "Listening on http://$HOST:$PORT"
echo "Model: $MODEL"
echo "Context: $CTX | slots: $PARALLEL | reasoning: off | content parser: pure"

if [ "${AA_GEMMA_JSON_SCHEMA:-0}" = "1" ]; then
  echo "Server-wide JSON schema: $SCHEMA_FILE"
else
  echo "Server-wide JSON schema: disabled"
fi

cd "$GEMMA_DIR"
exec "$LLAMA_SERVER" "${ARGS[@]}"

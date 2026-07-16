#!/bin/bash
# Repeatedly prompts an Ollama model and records tok/s for ai-stats.sh / mac-stats.sh
# to display in their "Last Inference" row.
#
# Run against a local Ollama (HOST=127.0.0.1) or a remote one over the LAN
# (HOST=aiserver.lan) — same script either way.
#
# usage: HOST=aiserver.lan MODEL=llama3.1:8b ./ollama-inference-loop.sh

HOST="${HOST:-127.0.0.1}"
MODEL="${MODEL:-llama3.1:8b}"
PROMPT="${PROMPT:-Explain quantum computing in detail}"
STATS_FILE="${STATS_FILE:-/tmp/ollama_last_stats.json}"

while true; do
  RESULT=$(curl -s "http://${HOST}:11434/api/generate" \
    -d "{\"model\":\"${MODEL}\",\"prompt\":\"${PROMPT}\",\"stream\":false}" \
    | jq '{model:.model, eval_count:.eval_count, tps: (.eval_count/(.eval_duration/1e9))}')
  echo "$RESULT" > "$STATS_FILE"
  echo "$RESULT" | jq '"tok/s: \(.tps | . * 10 | round / 10)  total tokens: \(.eval_count)  model: \(.model)"'
done

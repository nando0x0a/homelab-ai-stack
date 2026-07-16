#!/bin/bash
# Repeatedly prompts LM Studio's OpenAI-compatible API and records tok/s for
# ai-stats.sh / mac-stats.sh to display in their "Last Inference" row.
#
# The API doesn't return timing fields directly (unlike Ollama), so this
# times the request wall-clock and derives tok/s from the reported completion
# token count.
#
# Run against a local LM Studio server (HOST=127.0.0.1) or one being reached
# through LM Link on a remote GPU host — either way it's the same port.
#
# usage: HOST=aiserver.lan MODEL=qwen2.5-coder-14b ./lmstudio-inference-loop.sh

HOST="${HOST:-127.0.0.1}"
MODEL="${MODEL:-deepseek/deepseek-r1-distill-qwen-14b}"
PROMPT="${PROMPT:-Explain quantum computing in detail}"
STATS_FILE="${STATS_FILE:-/tmp/lmstudio_last_stats.json}"

while true; do
  START=$(date +%s%N)
  RESULT=$(curl -s "http://${HOST}:1234/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"${PROMPT}\"}],\"stream\":false}")
  END=$(date +%s%N)
  STATS=$(echo "$RESULT" | jq --argjson dur "$(( (END - START) / 1000000 ))" \
    '{model:.model, eval_count:.usage.completion_tokens, tps: (.usage.completion_tokens / ($dur/1000))}')
  echo "$STATS" > "$STATS_FILE"
  echo "$STATS" | jq '"tok/s: \(.tps | . * 10 | round / 10)  total tokens: \(.eval_count)  model: \(.model)"'
done

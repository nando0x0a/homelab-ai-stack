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
    | jq '{model:.model, input_tokens:.prompt_eval_count, output_tokens:.eval_count, total_tokens:(.prompt_eval_count+.eval_count), tps: (.eval_count/(.eval_duration/1e9)), total_tps: ((.prompt_eval_count+.eval_count)/((.prompt_eval_duration+.eval_duration)/1e9))}')
  echo "$RESULT" > "$STATS_FILE"
  echo "$RESULT" | jq '"tok/s: \(.tps | . * 10 | round / 10)  overall: \(.total_tps | . * 10 | round / 10) tok/s  in: \(.input_tokens)  out: \(.output_tokens)  model: \(.model)"'
done

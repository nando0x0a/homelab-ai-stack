#!/bin/bash
# Taps LM Studio's own event stream instead of polling — writes each
# completed prediction's stats to /tmp/mac_lmstudio_last_stats.json.
# Run in a background terminal alongside mac-stats.sh / ai-stats.sh.

export PATH="$PATH:$HOME/.lmstudio/bin"

echo "Monitoring LM Studio inference stats..."

lms log stream --stats --json --source model | python3 -c "
import sys, json

for line in sys.stdin:
    line = line.strip()
    if not line.startswith('{'): continue
    try:
        d = json.loads(line)
        data = d.get('data', {})
        if data.get('type') == 'llm.prediction.output':
            stats = data.get('stats', {})
            model = data.get('modelIdentifier', '?')
            out = {
                'model': model,
                'tps': stats.get('tokensPerSecond', 0),
                'eval_count': stats.get('predictedTokensCount', 0)
            }
            with open('/tmp/mac_lmstudio_last_stats.json', 'w') as f:
                json.dump(out, f)
            print(f'[stats] {model}  {out[\"tps\"]:.1f} tok/s  {out[\"eval_count\"]} tokens')
            sys.stdout.flush()
    except:
        pass
"

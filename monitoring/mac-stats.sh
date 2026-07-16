#!/bin/bash
# Terminal dashboard for the Mac client — GPU/CPU/RAM via powermetrics, plus
# loaded-model and last-inference stats for Ollama (local) and LM Studio
# (local or offloaded to the server via LM Link).
# usage: sudo ./mac-stats.sh | live: sudo watch -n 2 ./mac-stats.sh
# requires sudo for powermetrics

export PATH="$PATH:$HOME/.lmstudio/bin"

R=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'
CY=$'\033[36m'; GR=$'\033[32m'; YL=$'\033[33m'; RD=$'\033[31m'; WH=$'\033[97m'

cv() { # cv value warn crit unit
  awk "BEGIN{exit !($1>=$3)}" && echo -n "${B}${RD}$1$4${R}" && return
  awk "BEGIN{exit !($1>=$2)}" && echo -n "${B}${YL}$1$4${R}" && return
  echo -n "${B}${GR}$1$4${R}"
}

bar() { # bar val max len
  local f=$(awk "BEGIN{printf \"%d\",($1/$2)*$3}")
  local e=$(( $3 - f ))
  local out="${CY}["
  for ((i=0;i<f;i++)); do out+="█"; done
  for ((i=0;i<e;i++)); do out+="░"; done
  out+="]${R}"
  echo -n "$out"
}

tput cup 0 0
IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "no ip")
echo -n "${B}${WH}$(scutil --get ComputerName)${R} ${D}$(date '+%H:%M:%S')${R}  Apple Silicon  ${IP}"$'\033[K'
echo ""
echo "${D}────────────────────────────────────────────────────────────────${R}"

# ── POWERMETRICS SAMPLE ───────────────────────────────────────────────────────
PM=$(sudo powermetrics --samplers gpu_power,cpu_power -n 1 -i 500 2>/dev/null)

# GPU util — "GPU HW active residency: XX.XX%"
GPU_UTIL=$(echo "$PM" | grep "GPU HW active residency" | head -1 | awk '{gsub(/%/,"",$5); printf "%.0f", $5}')
GPU_UTIL=${GPU_UTIL:-0}

# GPU power — convert mW to W
GPU_PWR=$(echo "$PM" | grep "^GPU Power:" | head -1 | awk '{printf "%.1fW", $3/1000}' | tr -d '\r')

# CPU E-cluster active residency
E_UTIL=$(echo "$PM" | grep "E-Cluster HW active residency" | head -1 | grep -oE '[0-9]+\.[0-9]+%' | head -1 | tr -d '%' | awk '{printf "%.0f", $1}')
E_UTIL=${E_UTIL:-0}

# CPU P-cluster active residency
P_UTIL=$(echo "$PM" | grep "P-Cluster HW active residency" | head -1 | grep -oE '[0-9]+\.[0-9]+%' | head -1 | tr -d '%' | awk '{printf "%.0f", $1+0}')
P_UTIL=${P_UTIL:-0}

# Overall CPU — average of E and P clusters
CPU=$(awk "BEGIN{printf \"%.0f\",($E_UTIL+$P_UTIL)/2}")

# ── GPU ───────────────────────────────────────────────────────────────────────
echo -n "${B}${CY}GPU${R}  "; bar $GPU_UTIL 100 14; echo " $(cv $GPU_UTIL 40 80 "")%   ${B}${CY}Pwr${R} ${B}${GPU_PWR}${R}"$'\033[K'

# ── CPU ───────────────────────────────────────────────────────────────────────
echo -n "${B}${CY}CPU${R}  "; bar $CPU 100 14; echo " $(cv $CPU 50 80 "")%   ${D}E-core:${E_UTIL}%  P-core:${P_UTIL}%${R}"$'\033[K'

# ── RAM ───────────────────────────────────────────────────────────────────────
# page size 16384 bytes = 16 KiB
PAGE=16384
VMSTAT=$(vm_stat)
FREE=$(echo "$VMSTAT"    | awk '/Pages free/       {gsub(/\./,"",$3); print $3}')
ACTIVE=$(echo "$VMSTAT"  | awk '/Pages active/     {gsub(/\./,"",$3); print $3}')
INACTIVE=$(echo "$VMSTAT"| awk '/Pages inactive/   {gsub(/\./,"",$3); print $3}')
SPEC=$(echo "$VMSTAT"    | awk '/Pages speculative/{gsub(/\./,"",$3); print $3}')
WIRED=$(echo "$VMSTAT"   | awk '/Pages wired/      {gsub(/\./,"",$4); print $4}')
COMP=$(echo "$VMSTAT"    | awk '/Pages occupied by compressor/{gsub(/\./,"",$5); print $5}')

USED_PAGES=$(( ACTIVE + WIRED + COMP ))
TOTAL_PAGES=$(( FREE + ACTIVE + INACTIVE + SPEC + WIRED + COMP ))
USED_GB=$(awk "BEGIN{printf \"%.1f\",($USED_PAGES*$PAGE)/1024/1024/1024}")
TOTAL_GB=$(awk "BEGIN{printf \"%.0f\",($TOTAL_PAGES*$PAGE)/1024/1024/1024}")
RAM_PCT=$(awk "BEGIN{printf \"%.0f\",($USED_PAGES/$TOTAL_PAGES)*100}")

MEM_PRESSURE=$(memory_pressure 2>/dev/null | awk '/System-wide memory free percentage/{gsub(/%/,"",$5); print 100-$5}')
MEM_PRESSURE=${MEM_PRESSURE:-0}

echo ""
echo -n "${B}${CY}RAM${R}  "; bar $RAM_PCT 100 14; echo -n " ${B}${USED_GB}/${TOTAL_GB}GB${R} ($(cv $RAM_PCT 70 85 "")%)"$'\033[K'
echo "   ${B}${CY}Pressure${R} $(cv $MEM_PRESSURE 60 80 "%")"

# ── MODELS IN VRAM ────────────────────────────────────────────────────────────
echo "${D}────────────────────────────────────────────────────────────────${R}"
echo "${D}Models loaded  (consuming memory right now)${R}"

OLLAMA_PS=$(curl -sf --max-time 2 http://127.0.0.1:11434/api/ps 2>/dev/null)
if [ -n "$OLLAMA_PS" ]; then
  echo "$OLLAMA_PS" | python3 -c "
import sys,json
d=json.load(sys.stdin)
models=d.get('models',[])
if not models:
    print('\033[36mOllama    \033[0m\033[2mno models loaded\033[0m')
for m in models:
    n=m.get('name','?')
    v=m.get('size_vram',0)/1024**3
    ctx=m.get('details',{}).get('parameter_size','?')
    exp=m.get('expires_at','')[:16].replace('T',' ')
    print(f'\033[36mOllama    \033[0m\033[1m{n}\033[0m  {ctx}  ram:{v:.1f}GB  unloads:{exp[:16]}')
" 2>/dev/null
else
  echo "${CY}Ollama    ${R}${D}unreachable${R}"
fi

LMS_PS=$(lms ps 2>/dev/null | grep -v "^$" | grep -v "^Title" | grep -v "IDENTIFIER" | head -5)
LMS_SERVER=$(curl -sf --max-time 2 http://127.0.0.1:1234/v1/models 2>/dev/null)

if [ -n "$LMS_PS" ]; then
  echo "$LMS_PS" | while read -r line; do
    model=$(echo "$line" | awk '{print $2}' | cut -c1-30)
    size=$(echo "$line" | awk '{print $4, $5}')
    if [ -n "$LMS_SERVER" ]; then
      backend="${D}server${R}"
    else
      backend="${D}local${R}"
    fi
    printf "${CY}LMStudio  ${R}  ${B}%-30s${R} %-8s %s\n" "$model" "$size" "$backend"
  done
elif pgrep -x "LM Studio" > /dev/null 2>&1; then
  echo "${CY}LMStudio  ${R}  ${D}running · no model loaded${R}"
else
  echo "${CY}LMStudio  ${R}  ${D}off${R}"
fi

# ── INFERENCE STATS ───────────────────────────────────────────────────────────
echo "${D}────────────────────────────────────────────────────────────────${R}"
echo "${D}tok/s = generation only · overall = incl. prompt processing · in/out/total = tokens${R}"
python3 -c "
import json,time,os

def show(path, label):
    if not os.path.exists(path): return
    try:
        d=json.load(open(path))
        tps=d.get('tps',0)
        total_tps=d.get('total_tps',0)
        in_tok=d.get('input_tokens',0)
        out_tok=d.get('output_tokens',0)
        tot_tok=d.get('total_tokens',0)
        model=d.get('model','?')
        age=time.time()-os.path.getmtime(path)
        ts=time.strftime('%H:%M:%S', time.localtime(os.path.getmtime(path)))
        print(f'\033[36m{label:<10}\033[0m \033[2mlast inference\033[0m  model:\033[1m{model[:30]}\033[0m  \033[1m{tps:.1f} tok/s\033[0m  \033[2moverall:\033[0m\033[1m{total_tps:.1f} tok/s\033[0m  in:\033[1m{in_tok}\033[0m  out:\033[1m{out_tok}\033[0m  total:\033[1m{tot_tok}\033[0m  \033[2m@ {ts}\033[0m\033[K')
    except: pass

found = os.path.exists('/tmp/ollama_last_stats.json') or os.path.exists('/tmp/lmstudio_last_stats.json')
if not found:
    print('\033[2mNo inference data yet — run a load-testing loop to populate\033[0m')
show('/tmp/ollama_last_stats.json', 'Ollama')
show('/tmp/lmstudio_last_stats.json', 'LMStudio')
" 2>/dev/null

echo "${D}────────────────────────────────────────────────────────────────${R}"

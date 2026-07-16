#!/bin/bash
# Terminal dashboard for GPU/VRAM/inference stats on the inference server.
# usage: ./ai-stats.sh | live: watch -n 2 ./ai-stats.sh
#
# Reads /tmp/ollama_last_stats.json and /tmp/lmstudio_last_stats.json,
# which the load-testing loops (ollama-inference-loop.sh / lmstudio-inference-loop.sh) write.
#
# Set AISERVER_HOST if Ollama's API isn't reachable at localhost (e.g. running
# this dashboard from a different host than the one serving Ollama).
AISERVER_HOST="${AISERVER_HOST:-localhost}"

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

clear
echo -n "${B}${WH}$(hostname)${R} ${D}$(date '+%H:%M:%S')${R}  $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null | tr ',' ' ')"
echo ""
echo "${D}────────────────────────────────────────────────────────────────${R}"

# ── GPU ───────────────────────────────────────────────────────────────────────
IFS=',' read -r GU MU MT TM PW PL FN < <(nvidia-smi \
  --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit,fan.speed \
  --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
PW=${PW%.*}; PL=${PL%.*}
MP=$(awk "BEGIN{printf \"%.0f\",($MU/$MT)*100}")

echo -n "${B}${CY}GPU${R}  "; bar $GU 100 14; echo -n " $(cv $GU 40 80 "")%  "
echo -n "${B}${CY}VRAM${R} "; bar $MU $MT 14; echo -n " ${B}${MU}/${MT}MiB${R} ($(cv $MP 60 85 "")%)"
echo ""
echo "${B}${CY}Temp${R} $(cv $TM 65 80 "")°C   ${B}${CY}Pwr${R} ${B}${PW}/${PL}W${R}   ${B}${CY}Fan${R} ${B}${FN}%${R}"

# ── VRAM PROCESSES ────────────────────────────────────────────────────────────
echo "${D}────────────────────────────────────────────────────────────────${R}"
echo "${D}VRAM Processes  (what's consuming GPU memory)${R}"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null | \
while IFS=',' read -r pid pname pmem; do
  pname_raw=$(echo "$pname" | xargs | awk -F'/' '{print $NF}')
  pmem=$(echo "$pmem" | xargs)
  vpct=$(awk "BEGIN{printf \"%.0f\",($pmem/$MT)*100}")
  # infer owner from process name
  case "$pname_raw" in
    python*)  owner="Ollama" ;;
    node*)    owner="LMStudio" ;;
    comfyui*) owner="ComfyUI" ;;
    *)        owner="$pname_raw" ;;
  esac
  printf "  PID %-8s %-10s %-8s MiB  $(cv $vpct 40 70 "")%%  of VRAM\n" \
    "$(echo $pid|xargs)" "$owner" "$pmem"
done

# ── MODELS ────────────────────────────────────────────────────────────────────
echo "${D}────────────────────────────────────────────────────────────────${R}"
echo "${D}Models in VRAM  (loaded = consuming GPU memory right now)${R}"

OLLAMA_PS=$(curl -sf --max-time 2 "http://${AISERVER_HOST}:11434/api/ps" 2>/dev/null)
if [ -n "$OLLAMA_PS" ]; then
  echo "$OLLAMA_PS" | python3 -c "
import sys,json
d=json.load(sys.stdin)
models=d.get('models',[])
if not models:
    print('\033[36mOllama  \033[0m\033[2mno models loaded\033[0m')
for m in models:
    n=m.get('name','?')
    v=m.get('size_vram',0)/1024**3
    ctx=m.get('details',{}).get('parameter_size','?')
    exp=m.get('expires_at','')[:16].replace('T',' ')
    print(f'\033[36mOllama  \033[0m\033[1m{n}\033[0m  {ctx}  vram:{v:.1f}GB  unloads:{exp}')
" 2>/dev/null
else
  echo "${CY}Ollama  ${R}${D}unreachable${R}"
fi

LMS=$(lms ps 2>/dev/null | grep -v "^$" | grep -v "^Title" | grep -v "IDENTIFIER" | head -3)
if [ -n "$LMS" ]; then
  echo "$LMS" | while read -r line; do
    id=$(echo "$line" | awk '{print $1}')
    model=$(echo "$line" | awk '{print $2}')
    status=$(echo "$line" | awk '{print $3}')
    size=$(echo "$line" | awk '{print $4" "$5}')
    printf "${CY}LMStudio${R}  ${B}%-35s${R} %-6s %s\n" "$model" "$status" "$size"
  done
else
  echo "${CY}LMStudio${R}  ${D}no models loaded${R}"
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
        print(f'\033[36m{label:<10}\033[0m \033[2mlast inference\033[0m  model:\033[1m{model}\033[0m  \033[1m{tps:.1f} tok/s\033[0m  \033[2moverall:\033[0m\033[1m{total_tps:.1f} tok/s\033[0m  in:\033[1m{in_tok}\033[0m  out:\033[1m{out_tok}\033[0m  total:\033[1m{tot_tok}\033[0m  \033[2m@ {ts}\033[0m')
    except: pass

found = os.path.exists('/tmp/ollama_last_stats.json') or os.path.exists('/tmp/lmstudio_last_stats.json')
if not found:
    print('\033[2mNo inference data yet — run a load-testing loop to populate\033[0m')
show('/tmp/ollama_last_stats.json', 'Ollama')
show('/tmp/lmstudio_last_stats.json', 'LMStudio')
" 2>/dev/null

# ── CPU & RAM ─────────────────────────────────────────────────────────────────
echo "${D}────────────────────────────────────────────────────────────────${R}"
CPU=$(grep 'cpu ' /proc/stat | awk '{u=$2+$4;t=$2+$3+$4+$5;printf "%.0f",u*100/t}')
read -r MT MU <<< $(free -m | awk '/^Mem:/{print $2,$3}')
MUG=$(awk "BEGIN{printf \"%.1f\",$MU/1024}")
MTG=$(awk "BEGIN{printf \"%.0f\",$MT/1024}")
MP=$(awk "BEGIN{printf \"%.0f\",($MU/$MT)*100}")
echo -n "${B}${CY}CPU${R}  "; bar $CPU 100 14; echo -n " $(cv $CPU 50 80 "")%   "
echo -n "${B}${CY}RAM${R}  "; bar $MU $MT 14; echo " ${B}${MUG}/${MTG}GB${R} ($(cv $MP 60 85 "")%)"

# ── CONTAINERS ────────────────────────────────────────────────────────────────
echo "${D}────────────────────────────────────────────────────────────────${R}"
echo "${D}Container Stats  (CPU/RAM per Docker service, not GPU)${R}"
docker stats --no-stream --format "{{.Name}}\t{{.CPUPerc}}\t{{.MemPerc}}\t{{.MemUsage}}" \
  ollama open-webui comfyui jupyterlab 2>/dev/null | \
while IFS=$'\t' read -r name cpu mem memusage; do
  mu=$(echo "$memusage" | cut -d'/' -f1 | xargs)
  printf "${D}%-14s${R}  cpu:%-8s mem:%-7s %s\n" "$name" "$cpu" "$mem" "$mu"
done
echo "${D}────────────────────────────────────────────────────────────────${R}"

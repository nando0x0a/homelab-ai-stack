#!/bin/bash
# Terminal dashboard for Claude + Gemini usage/cost.
# usage: ./cloud-ai-stats.sh | live: watch -n 15 ./cloud-ai-stats.sh
# --no-usage: skip both sections (Claude has real spend figures + a masked
# personal email, Gemini has real spend figures) — required before piping
# output to any non-private channel/bot.
#
# Split 2026-08-10 from the retired ai-stats.sh (see
# ai-stats.sh.retired-20260810) to match the local-ai-stats/cloud-ai-stats web
# app split. Claude section is unchanged (calls `ccusage` + reads local
# ~/.claude files directly, no dependency on any container). Gemini section is
# new, sourced from the cloud-ai-stats web app's own /api/gemini endpoint
# (real Hermes call-log data + pricing) rather than re-deriving that logic in
# bash.
CLOUD_AI_STATS_URL="${CLOUD_AI_STATS_URL:-http://192.168.0.6:9899}"
SKIP_USAGE=0
for arg in "$@"; do
  [ "$arg" = "--no-usage" ] && SKIP_USAGE=1
done

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
echo "${B}${WH}$(hostname)${R} ${D}$(date '+%H:%M:%S')${R}"
echo "${D}────────────────────────────────────────────────────────────────${R}"

if [ "$SKIP_USAGE" = "1" ]; then
  echo "${D}(--no-usage: Claude + Gemini sections skipped)${R}"
  exit 0
fi

# ── CLAUDE CODE USAGE ═══════════════════════════════════════════════════════════
echo "${D}════════════════════════════════════════════════════════════════${R}"
echo "${D}Claude Code usage (ccusage) · cost is notional API-rate pricing, not a subscription bill${R}"
echo "${D}· Account-wide — shared across every Claude surface (CLI, desktop, Cowork) ·${R}"
python3 -c "
import json,os
try:
    d=json.load(open(os.path.expanduser('~/.claude.json')))
    a=d.get('oauthAccount',{})
    email=a.get('emailAddress','?')
    if '@' in email:
        local,domain=email.split('@',1)
        email=f'{local[:3]}...@{domain}'
    plan=a.get('organizationType','?')
    print(f'\033[36mAccount \033[0m\033[1m{email}\033[0m  plan:\033[1m{plan}\033[0m')
except Exception:
    print('\033[36mAccount \033[0m\033[2munavailable\033[0m')
" 2>/dev/null
# Which Claude surface (CLI, desktop app, Cowork, ...) last touched this account —
# clientDataCacheSlots is synced account-wide by Anthropic's servers, not scraped locally.
python3 -c "
import json,os,time
try:
    d=json.load(open(os.path.expanduser('~/.claude.json')))
    slots=d.get('clientDataCacheSlots',{})
    seen={}
    for v in slots.values():
        ep=v.get('entrypoint','?')
        at=v.get('at',0)/1000
        if ep not in seen or at>seen[ep]:
            seen[ep]=at
    if not seen:
        print('\033[36mClients \033[0m\033[2munavailable\033[0m')
    else:
        now=time.time()
        parts=[]
        for ep,at in sorted(seen.items(), key=lambda x:-x[1]):
            age=now-at
            if age<3600: age_s=f'{int(age/60)}m ago'
            elif age<86400: age_s=f'{age/3600:.1f}h ago'
            else: age_s=f'{age/86400:.1f}d ago'
            parts.append(f'\033[1m{ep}\033[0m {age_s}')
        print('\033[36mClients \033[0m' + '  ·  '.join(parts))
except Exception:
    print('\033[36mClients \033[0m\033[2munavailable\033[0m')
" 2>/dev/null

# Real 5-hour/weekly quota from Claude Code's own rate_limits (cached by the statusLine hook,
# populated only while a Claude Code session is actively rendering — see ~/.claude/settings.json)
RL_DATA=$(python3 -c "
import json,os,time
p=os.path.expanduser('~/.claude/rate_limits_cache.json')
try:
    d=json.load(open(p))
    rl=d.get('rate_limits',{})
    age=time.time()-d.get('cached_at',0)
    age_s=f'{int(age/60)}m ago' if age<3600 else f'{age/3600:.1f}h ago'
    fh=rl.get('five_hour',{}); sd=rl.get('seven_day',{})
    fh_pct=fh.get('used_percentage'); sd_pct=sd.get('used_percentage')
    fh_pct=round(fh_pct) if fh_pct is not None else None
    sd_pct=round(sd_pct) if sd_pct is not None else None
    fh_ts=time.strftime('%a %H:%M', time.localtime(fh.get('resets_at'))) if fh.get('resets_at') else '?'
    sd_ts=time.strftime('%a %H:%M', time.localtime(sd.get('resets_at'))) if sd.get('resets_at') else '?'
    print(f'{fh_pct if fh_pct is not None else -1}|{sd_pct if sd_pct is not None else -1}|{fh_ts}|{sd_ts}|{age_s}')
except Exception:
    print('ERR')
" 2>/dev/null)

if [ "$RL_DATA" != "ERR" ] && [ -n "$RL_DATA" ]; then
  IFS='|' read -r FH_PCT SD_PCT FH_TS SD_TS AGE_S <<< "$RL_DATA"
  if [ "$FH_PCT" != "-1" ]; then
    echo -n "${B}${CY}5h Limit${R} "; bar $FH_PCT 100 14; echo " $(cv $FH_PCT 60 85 "")%  resets ${FH_TS}"
  else
    echo "${CY}5h Limit${R} ${D}unavailable${R}"
  fi
  if [ "$SD_PCT" != "-1" ]; then
    echo -n "${B}${CY}Wk Limit${R} "; bar $SD_PCT 100 14; echo " $(cv $SD_PCT 60 85 "")%  resets ${SD_TS}"
  else
    echo "${CY}Wk Limit${R} ${D}unavailable${R}"
  fi
  echo "${D}(rate limits as of ${AGE_S})${R}"
else
  echo "${CY}Limits  ${R}${D}no cached rate-limit data yet — open a Claude Code session to populate${R}"
fi

echo "${D}· Local to aiserver's CLI only — excludes desktop/Cowork usage ·${R}"
echo "${D}Block   = current 5-hour billing window: tokens/cost/burn rate on this CLI, resets on the timer shown${R}"
CCUSAGE_BLOCK=$(ccusage blocks --active --json 2>/dev/null)
CCUSAGE_DAILY=$(ccusage daily --json --since "$(date +%Y%m%d)" 2>/dev/null)

if [ -n "$CCUSAGE_BLOCK" ]; then
  echo "$CCUSAGE_BLOCK" | python3 -c "
import sys,json
try:
    blocks=json.load(sys.stdin).get('blocks',[])
    if not blocks:
        print('\033[36mBlock   \033[0m\033[2mno active session\033[0m')
    else:
        b=blocks[0]
        models=','.join(m.replace('claude-','') for m in b.get('models',[]))
        cost=b.get('costUSD',0)
        tok=b.get('totalTokens',0)
        burn=b.get('burnRate',{}).get('costPerHour',0) or 0
        rem=b.get('projection',{}).get('remainingMinutes',0) or 0
        h,m=divmod(int(rem),60)
        print(f'\033[36mBlock   \033[0m\033[1m{models}\033[0m  tokens:\033[1m{tok:,}\033[0m  cost:\033[1m\${cost:.2f}\033[0m  burn:\033[1m\${burn:.2f}/hr\033[0m  resets in \033[1m{h}h{m:02d}m\033[0m')
except Exception:
    print('\033[36mBlock   \033[0m\033[2munavailable\033[0m')
" 2>/dev/null
else
  echo "${CY}Block   ${R}${D}unavailable${R}"
fi

echo "${D}Today   = total tokens/cost on this CLI since midnight, across all of today's sessions${R}"
if [ -n "$CCUSAGE_DAILY" ]; then
  echo "$CCUSAGE_DAILY" | python3 -c "
import sys,json
try:
    t=json.load(sys.stdin).get('totals',{})
    tok=t.get('totalTokens',0)
    cost=t.get('totalCost',0)
    print(f'\033[36mToday   \033[0m tokens:\033[1m{tok:,}\033[0m  cost:\033[1m\${cost:.2f}\033[0m')
except Exception:
    print('\033[36mToday   \033[0m\033[2munavailable\033[0m')
" 2>/dev/null
else
  echo "${CY}Today   ${R}${D}unavailable${R}"
fi

echo "${D}Context = this specific conversation's context-window usage, resets on /clear or a new session${R}"
python3 -c "
import os,glob,json

WINDOWS={
    'claude-sonnet-5':1_000_000,'claude-opus-5':1_000_000,'claude-fable-5':1_000_000,
    'claude-sonnet-4-6':1_000_000,'claude-haiku-4-5-20251001':200_000,
}

def latest_session():
    paths=glob.glob(os.path.expanduser('~/.claude/projects/*/*.jsonl'))
    return max(paths,key=os.path.getmtime) if paths else None

def last_usage(path):
    with open(path,'rb') as f:
        f.seek(0,os.SEEK_END)
        size=f.tell()
        f.seek(max(0,size-200000))
        data=f.read().decode('utf-8',errors='ignore')
    for line in reversed(data.split(chr(10))):
        if not line.strip(): continue
        try:
            obj=json.loads(line)
        except Exception:
            continue
        usage=obj.get('message',{}).get('usage')
        if usage:
            return obj['message'].get('model','?'), usage.get('input_tokens',0)+usage.get('cache_creation_input_tokens',0)+usage.get('cache_read_input_tokens',0)
    return None

try:
    p=latest_session()
    r=last_usage(p) if p else None
    if not r:
        print('\033[36mContext \033[0m\033[2mno active session\033[0m')
    else:
        model,ctx=r
        window=WINDOWS.get(model,1_000_000)
        pct=ctx/window*100
        print(f'\033[36mContext \033[0m\033[1m{model}\033[0m  {ctx:,}/{window:,} tokens (\033[1m{pct:.0f}%\033[0m used, \033[1m{100-pct:.0f}%\033[0m left)')
except Exception:
    print('\033[36mContext \033[0m\033[2munavailable\033[0m')
" 2>/dev/null

# ── GEMINI USAGE ═══════════════════════════════════════════════════════════════
echo "${D}════════════════════════════════════════════════════════════════${R}"
echo "${D}Gemini usage (Hermes) · cost is a self-computed estimate from published API pricing${R}"
echo "${D}· \$10 Google Developer Program credit · Today/Week/Month across all 7 Hermes profiles ·${R}"
GEMINI_JSON=$(curl -sf --max-time 3 "${CLOUD_AI_STATS_URL}/api/gemini" 2>/dev/null)
if [ -n "$GEMINI_JSON" ]; then
  echo "$GEMINI_JSON" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    t=d['totals']
    for label,key in (('Today','today'),('This Week','week'),('This Month','month')):
        w=t[key]
        tok=w['input']+w['output']
        print(f'\033[36m{label:<10}\033[0m tokens:\033[1m{tok:,}\033[0m  cost:\033[1m\${w[\"cost\"]:.2f}\033[0m  calls:\033[1m{w[\"calls\"]}\033[0m')
    print()
    for m in d.get('by_model',[]):
        print(f'\033[36mModel   \033[0m\033[1m{m[\"model\"]}\033[0m  in:{m[\"input\"]:,}  cached:{m[\"cache\"]:,}  out:{m[\"output\"]:,}  cost:\033[1m\${m[\"cost\"]:.2f}\033[0m')
    for p in d.get('by_profile',[]):
        print(f'\033[36mProfile \033[0m\033[1m{p[\"profile\"]:<20}\033[0m calls:{p[\"calls\"]}  cost:\033[1m\${p[\"cost\"]:.2f}\033[0m')
except Exception as e:
    print(f'\033[2munavailable ({e})\033[0m')
" 2>/dev/null
else
  echo "${CY}Gemini  ${R}${D}unavailable (cloud-ai-stats app unreachable at ${CLOUD_AI_STATS_URL})${R}"
fi
echo "${D}════════════════════════════════════════════════════════════════${R}"

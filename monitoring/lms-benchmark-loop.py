#!/usr/bin/env python3
# Continuously benchmarks whatever model is currently loaded in LM Studio by
# driving `lms chat` directly (rather than the HTTP API), parsing its --stats
# output, and writing tok/s + token count for the dashboards to display.
#
# Useful when you want a quick, repeatable throughput read on a model right
# after loading it, without wiring up a full HTTP client.
import subprocess, json, os, re, sys, time, threading

PATH = os.path.expandvars("$HOME/.lmstudio/bin") + ":" + os.environ.get("PATH", "")
env = {**os.environ, "PATH": PATH}

def get_loaded_model():
    out = subprocess.run(["lms", "ps"], capture_output=True, text=True, env=env).stdout
    for line in out.splitlines():
        if line and not line.startswith("IDENTIFIER"):
            parts = line.split()
            if parts:
                return parts[0]
    return None

def spinner(stop_event, start_time):
    frames = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
    i = 0
    while not stop_event.is_set():
        print(f"\r{frames[i%len(frames)]} generating... {time.time()-start_time:.1f}s", end="", flush=True)
        i += 1
        time.sleep(0.1)

n = 1
while True:
    model = get_loaded_model()
    if not model:
        print("No model loaded in LM Studio — load one first")
        time.sleep(5)
        continue

    stop = threading.Event()
    start = time.time()
    t = threading.Thread(target=spinner, args=(stop, start))
    t.start()

    try:
        out = subprocess.run(
            ["lms", "chat", model, "-p", "Hi.", "--stats",
             "--system-prompt", "Reply in one short sentence. No thinking."],
            capture_output=True, text=True, env=env, timeout=30
        ).stdout
    except subprocess.TimeoutExpired:
        stop.set(); t.join()
        print("\rtimeout — retrying")
        continue

    stop.set(); t.join()

    tps    = re.search(r"Tokens/Second:\s+([\d.]+)", out)
    tokens = re.search(r"Predicted Tokens:\s+(\d+)", out)

    if tps and tokens:
        tps, tokens = float(tps.group(1)), int(tokens.group(1))
        stats = {"model": model, "tps": tps, "eval_count": tokens}
        open("/tmp/mac_lmstudio_last_stats.json", "w").write(json.dumps(stats))
        print(f"\r#{n}  tok/s: {tps:.1f}  tokens: {tokens}  {time.time()-start:.1f}s  model: {model}")
        n += 1
    else:
        print(f"\rno stats found — output: {out[:100]}")

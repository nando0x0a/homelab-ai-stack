# Inference Runbook

> IPs are genericized (`aiserver.lan`) — see the [README notes](../README.md#notes). Load-testing loops referenced below live in [`../monitoring/`](../monitoring/).

## 1. Ollama

Runs as a Docker container on the shared `infra` network. API port `11434`. Open WebUI connects to it internally via `http://ollama:11434`.

### 1.1 Run models

**From the server (docker exec):**
```bash
# list pulled models
docker exec -it ollama ollama list

# interactive chat REPL
docker exec -it ollama ollama run <model>

# one-shot prompt (non-interactive)
docker exec -it ollama ollama run <model> "your prompt here"

# show loaded models + context window in use
docker exec -it ollama ollama ps
```

**From any machine on the LAN (REST API):**
```bash
# list models
curl http://aiserver.lan:11434/api/tags | jq

# one-shot generate (returns token stats in response)
curl http://aiserver.lan:11434/api/generate \
  -d '{"model": "<model>", "prompt": "your prompt", "stream": false}' | jq

# chat with message history
curl http://aiserver.lan:11434/api/chat \
  -d '{"model": "<model>", "messages": [{"role": "user", "content": "your prompt"}], "stream": false}' | jq

# generate embeddings (RAG use case)
curl http://aiserver.lan:11434/api/embeddings \
  -d '{"model": "<embedding-model>", "prompt": "text to embed"}' | jq
```

**Via Open WebUI (browser):** chat UI, model selector, token/s display per response.

### 1.2 Model management

```bash
docker exec -it ollama ollama pull <model>     # pull a model
docker exec -it ollama ollama rm <model>       # remove a model
docker exec -it ollama ollama show <model>     # model info (params, context length)
du -sh /opt/docker/ollama/models/blobs/        # disk usage of model blobs
```

### 1.3 Token stats from the API response

The `/api/generate` and `/api/chat` endpoints (with `"stream": false`) return:

| Field | Meaning |
|---|---|
| `prompt_eval_count` | Input tokens processed |
| `prompt_eval_duration` | Time to process prompt (ns) |
| `eval_count` | Output tokens generated |
| `eval_duration` | Time to generate output (ns) |
| `total_duration` | End-to-end wall time (ns) |

**Tokens/s formulas:**
- Generation-only: `eval_count / eval_duration * 1e9`
- Overall (incl. prompt processing): `(prompt_eval_count + eval_count) / (prompt_eval_duration + eval_duration) * 1e9`

This is exactly what [`monitoring/ollama-inference-loop.sh`](../monitoring/ollama-inference-loop.sh) computes on every iteration.

---

## 2. Open WebUI

Browser-based chat UI. Connects to Ollama internally; no API key needed on the LAN.

**Auth:** first login creates the admin account; signup disabled after that.

**Per-response display:** tokens/s, model used, time to first token.

**Other features:** model selector across Ollama + all LM Studio models (via the OpenAI-compatible API), system prompt/persona config, chat history, RAG document upload.

---

## 3. LM Studio

Two systemd services:
- **daemon** — core service; LM Link compute device for the Mac client
- **server** — OpenAI-compatible HTTP API on `0.0.0.0:1234`; starts after the daemon

**API base URL:** `http://aiserver.lan:1234/v1` — Open WebUI connects via `OPENAI_API_BASE_URL`.

### 3.1 Commands (from the server)

```bash
systemctl status lmstudio-daemon.service
systemctl status lmstudio-server.service

lms link status                 # LM Link connection status
lms ls                           # list local models
lms ps                           # show loaded model(s)
lms daemon status                # daemon health
lms get <model-id> -y            # download a model
curl http://aiserver.lan:1234/v1/models | jq
```

> LM Studio and Ollama share the same physical GPU — don't run both under load simultaneously.

---

## 4. VRAM Budget

See [`docs/setup-runbook.md`](setup-runbook.md#vram-budget--concurrent-workloads) for the full table. Ollama frees VRAM automatically once a model goes idle past its keep-alive window.

---

## 5. Monitoring & Load-Testing

### 5.1 ai-stats — compact terminal dashboard

[`monitoring/ai-stats.sh`](../monitoring/ai-stats.sh) gives a single-screen view: GPU util + VRAM bars, VRAM processes with owner and % usage, last-inference stats per engine, loaded models, CPU/RAM bars, Docker container stats.

```bash
# one-shot snapshot
./ai-stats.sh

# live (2s refresh)
watch -n 2 ./ai-stats.sh
```

The "Last Inference" row is populated by the load-testing loops below writing to `/tmp/ollama_last_stats.json` and `/tmp/lmstudio_last_stats.json` — run a dashboard in one terminal and a loop in another.

### 5.2 Load-testing loops

These continuously re-prompt the currently loaded model and record throughput, rather than producing a single one-off benchmark number:

```bash
# Ollama — repeatedly prompts the local Ollama model
./monitoring/ollama-inference-loop.sh

# LM Studio — same idea against the OpenAI-compatible API
./monitoring/lmstudio-inference-loop.sh

# Python variant — drives `lms chat` directly with a live spinner
python3 monitoring/lms-benchmark-loop.py

# Event-stream variant — taps LM Studio's own stats stream instead of polling
./monitoring/lms-stats-stream.sh
```

Each writes a small JSON stats file (`model`, `tps`, `total_tps`, `input_tokens`, `output_tokens`, `total_tokens`) that both the dashboards and, potentially, other tooling can consume.

### 5.3 GPU — quick CLI

```bash
nvidia-smi                                                    # one-shot snapshot
watch -n 1 nvidia-smi                                         # live full panel
watch -n 1 'nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader'
nvidia-smi pmon -s u                                          # GPU process list
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader
```

### 5.4 Container resource usage

```bash
docker stats                          # live CPU/RAM for all containers
docker stats ollama                   # one container
docker logs ollama --tail 50 -f       # tail logs
```

### 5.5 Grafana dashboards (persistent metrics)

| Dashboard | Shows |
|---|---|
| NVIDIA GPU Metrics | VRAM usage, GPU utilization, memory bandwidth %, temperature, power draw |
| Node Exporter Full | CPU, RAM, disk I/O, network throughput |

---

## 6. Mac Client — LM Studio + Ollama

**LM Studio architecture:**
- **LM Link** — the compute layer. Connects the Mac to the server as a remote GPU device. When active, all LM Studio inference runs on the server's GPU, not the Mac.
- **LM Studio server (port 1234)** — the API layer. An OpenAI-compatible HTTP server in front of whatever compute is active. When LM Link is connected, calls to `http://127.0.0.1:1234/v1` transparently route through LM Link to the server. There's no separate LM Link API — port 1234 is the only programmatic entry point.
- **Flow:** `curl → LM Studio server (:1234) → LM Link → server GPU`

**Ollama on the Mac:** `http://127.0.0.1:11434` — runs locally on Apple Silicon, no LM Link involved.

### 6.1 mac-stats dashboard

[`monitoring/mac-stats.sh`](../monitoring/mac-stats.sh) — terminal dashboard: GPU util + power (via `powermetrics`), CPU E/P-core utilization, unified RAM + memory pressure, Ollama + LM Studio loaded models (with LM Link detection), last-inference stats per engine.

```bash
# requires sudo for powermetrics
sudo ./mac-stats.sh

# live (2s refresh)
sudo watch -n 2 ./mac-stats.sh
```

### 6.2 Ollama (Mac — local Apple Silicon inference)

```bash
ollama list                                     # list models
ollama pull <model>                             # pull a model
ollama run <model>                              # interactive chat
curl -s http://127.0.0.1:11434/api/tags | jq    # API
```

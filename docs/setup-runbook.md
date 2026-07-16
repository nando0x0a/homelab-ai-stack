# Setup Runbook

> IPs are genericized (`aiserver.lan`, `<lan-subnet>`) — see the [README notes](../README.md#notes).

## Build Log

| Phase | Scope | Status |
|---|---|---|
| — | eGPU dock + GPU hardware install | ✅ Done |
| 0 | Storage layout + host firewall | ✅ Done |
| 1 | GPU drivers + CUDA + Docker GPU runtime | ✅ Done |
| 2 | Ollama (Docker) + starter models | ✅ Done |
| 3 | Open WebUI + JupyterLab (Docker) | ✅ Done |
| 4 | LangChain / LangGraph / RAG | ⏳ Pending — examples live in JupyterLab |
| 5 | ComfyUI (Docker) | ✅ Container up; checkpoints added separately |
| 6 | LM Studio / LM Link (native) | ✅ Done — remote-GPU compute device for the Mac client + OpenAI-compatible API |

## Hardware Reference

| Component | Detail |
|---|---|
| CPU | AMD Ryzen 7 8845HS — 8C/16T, up to 5.1 GHz |
| RAM | 96 GB DDR5-5600 (2× 48 GB SO-DIMM) |
| OS SSD | 4 TB PCIe NVMe |
| GPU dock | eGPU enclosure — OCuLink PCIe 4.0 x4 (64 Gbps) |
| GPU | RTX 3090 24 GB GDDR6X |
| GPU PSU | Corsair SF850 |
| UPS | 1500VA/1000W pure sine wave |

## Service Layout — `/opt/docker/<service>/`

Every AI service follows the host's existing `/opt/docker/` convention:

```
/opt/docker/
├── .env                    # shared (PUID, PGID, TZ, secrets)
├── dc.sh                   # wrapper: ./dc.sh <service> <compose-cmd>
├── ollama/
│   ├── docker-compose.yml
│   └── models/             # bind-mount → /root/.ollama
├── open-webui/
│   ├── docker-compose.yml
│   └── data/               # bind-mount → /app/backend/data
├── comfyui/
│   ├── docker-compose.yml
│   ├── models/             # bind-mount → /opt/ComfyUI/models
│   ├── output/             # bind-mount → /opt/ComfyUI/output
│   └── custom_nodes/
└── jupyterlab/
    ├── docker-compose.yml
    ├── notebooks/          # bind-mount → /home/jovyan/notebooks
    └── work/
```

All services run on a shared external Docker network (`infra`). Internal service-to-service calls use container names — e.g. Open WebUI reaches Ollama at `http://ollama:11434`, never the host's LAN IP.

## Endpoints

| Service | URL | Auth |
|---|---|---|
| Ollama API | `http://aiserver.lan:11434` | none (LAN-scoped firewall) |
| Open WebUI | `http://aiserver.lan:3001` | first login = admin; signup disabled |
| ComfyUI | `http://aiserver.lan:8188` | none |
| JupyterLab | `http://aiserver.lan:8888/?token=…` | token in `.env` |
| Prometheus | `http://aiserver.lan:9090` | none |
| Grafana | `http://aiserver.lan:3030` | admin / see `.env` |
| LM Studio API | `http://aiserver.lan:1234/v1` | none (firewall-scoped to LAN + Docker bridge) |
| LM Studio (LM Link) | LM Link only | `lms` CLI; systemd service |

## Ollama Model Management

```bash
docker exec ollama ollama list                    # show models
docker exec ollama ollama pull <model>            # add model
du -sh /opt/docker/ollama/models/blobs/           # blob disk usage
```

Ollama does not split a single model across multiple GPUs — all VRAM on the card goes to one model at a time. If multi-GPU sharding is ever needed, that's the point to switch to vLLM instead.

## LM Studio / LM Link (Native — Remote-GPU Compute Offload)

Two systemd services:
- **daemon** — core service; LM Link compute device for the Mac client
- **server** — OpenAI-compatible API on `0.0.0.0:1234`; starts after the daemon

```bash
lms ls                          # list all models (local + remote client)
lms ps                          # show loaded models
lms link status                 # LM Link connection status
lms daemon status               # daemon health
lms get <model> -y              # download a model
```

## Common Operations

```bash
# 1. Service control (from /opt/docker)
./dc.sh ollama restart           # restart one
./dc.sh ollama logs -f           # tail logs
./dc.sh open-webui pull && ./dc.sh open-webui up -d   # update image

# 2. GPU usage
nvidia-smi                       # one-shot
watch -n 1 nvidia-smi            # live

# 3. Pull / list models
docker exec ollama ollama list
docker exec ollama ollama pull <model>
```

## Monitoring Stack — Grafana + Prometheus

### Architecture

```
nvidia-gpu-exporter :9835  ─┐
node-exporter (host) :9100  ├─→  Prometheus :9090  →  Grafana :3030
prometheus self-scrape      ─┘
```

- **nvidia-gpu-exporter** — GPU metrics via `nvidia-smi`; runs on the `infra` network with the GPU device nodes passed through.
- **node-exporter** — host network mode; firewall-restricted to the Docker bridge subnet only.
- **Prometheus** — 30-day retention, lifecycle API enabled.
- **Grafana** — data persisted to a bind mount; Prometheus datasource auto-provisioned.

### Grafana dashboards

| Dashboard | Metrics |
|---|---|
| NVIDIA GPU Metrics | VRAM usage/%, GPU utilization, memory bandwidth %, temperature, power draw |
| Node Exporter Full | CPU, RAM, disk I/O, network throughput |

### Grafana auth note

Some Grafana versions reset the admin password to the `GF_SECURITY_ADMIN_PASSWORD` env var value on every container restart — a UI password change alone won't survive `docker compose up -d`. Use `docker exec grafana grafana cli admin reset-admin-password <new>` and update the env var to match so it persists across restarts.

## Port + Firewall Reference

| Port | Service | Firewall |
|---|---|---|
| 22 | SSH | LAN |
| 3000 | Homepage | LAN |
| 3001 | Open WebUI | LAN |
| 3030 | Grafana | LAN |
| 8188 | ComfyUI | LAN |
| 8888 | JupyterLab | LAN |
| 9000/9443 | Portainer | LAN |
| 9090 | Prometheus | LAN |
| 1234 | LM Studio API | LAN + Docker bridge subnet |
| 9100 | node-exporter | Docker bridge subnet only |
| 11434 | Ollama API | LAN |
| 19999 | Netdata | LAN |

> Gotcha: a firewall rule scoped to the LAN subnet alone isn't enough for services bound directly to the host (host network mode) if a container also needs to reach them by the host's LAN IP — the container's own subnet needs an explicit allow rule too, in addition to the LAN rule.

## VRAM Budget — Concurrent Workloads

| Workload | VRAM | Via |
|---|---|---|
| Small general-chat model (~2-5B) | ~2-5 GB | Ollama |
| Mid-size reasoning model (~8-14B) | ~5-9 GB | Ollama / LM Studio |
| Large reasoning/general model (~32B) | ~19 GB | LM Studio |
| Flagship model (~70B) | ~40 GB ⚠ requires CPU offload | LM Studio |
| SDXL generation | ~7 GB | ComfyUI |
| Flux.1-schnell (quantized) | ~12 GB | ComfyUI |
| ComfyUI + a 14B LLM concurrently | ~16 GB ✅ | — |
| Flux + a 14B LLM concurrently | ~21 GB ⚠ tight | — |

Ollama unloads idle models automatically after a configurable keep-alive window, freeing VRAM without manual intervention. LM Studio and Ollama share the same physical GPU — don't run both under load simultaneously.

## ComfyUI — Adding Models

```bash
# 1. SDXL base checkpoint (~7 GB)
sudo wget -O /opt/docker/comfyui/models/checkpoints/sd_xl_base_1.0.safetensors \
  "https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors"

# 2. Matching VAE
sudo wget -O /opt/docker/comfyui/models/vae/sdxl_vae.safetensors \
  "https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors"

sudo chown -R $(whoami):$(whoami) /opt/docker/comfyui/models
```

## Validation Checklist

- [x] `nvidia-smi` shows the GPU with full VRAM available
- [x] `docker info` shows the `nvidia` runtime
- [x] Ollama container starts, `ollama list` shows the starter models
- [x] A test prompt responds; VRAM rises in `nvidia-smi`
- [x] Open WebUI loads and sees both Ollama and LM Studio models
- [x] LM Studio API server running on its configured port
- [x] ComfyUI loads; `system_stats` reports the GPU
- [x] JupyterLab loads; `torch.cuda.is_available() == True`
- [x] Host firewall active with LAN-scoped rules
- [x] Prometheus scraping GPU + host metrics (all targets healthy)
- [x] Grafana dashboards populated
- [x] LM Studio daemon installed and running
- [x] LM Link connected to the Mac client as a remote compute device

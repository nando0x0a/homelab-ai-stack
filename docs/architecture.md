# Architecture & Design Principles

## Setup Context

The server is headless — the Mac is the only client.

- No monitor, keyboard, or mouse on the server
- All management via SSH from the Mac
- All UI services accessed via browser on the Mac → `http://aiserver.lan:<port>`
- All API calls originate from the Mac or other homelab services over the LAN
- No GUI, X11, or display dependencies anywhere in the stack

| How you interact | Tool | From |
|---|---|---|
| Server management | SSH | Mac terminal |
| Chat / model UI | Open WebUI (browser) | Mac → `aiserver.lan:3001` |
| Notebooks | JupyterLab (browser) | Mac → `aiserver.lan:8888` |
| Image generation | ComfyUI (browser) | Mac → `aiserver.lan:8188` |
| Model API | Ollama REST | Mac / LangChain / other services |
| Container management | Portainer (browser) | Mac → `aiserver.lan:9443` |
| Host metrics | Netdata (browser) | Mac → `aiserver.lan:19999` |

This means every Docker service binds to `0.0.0.0` (not `127.0.0.1`), and the firewall opens each port to the LAN subnet only. Nothing needs to run locally on the server beyond SSH.

## Core Principles

> The GPU is the center of the stack. The host handles hosting, services, and orchestration. Stabilize each layer before adding the next.

**Rule of thumb:** if it's infrastructure, it goes on the OS. If it's AI software, it goes in Docker. The host stays minimal — the containers do the interesting work.

### Persistent Storage Rule

Models and app data must survive container updates and restarts. Every AI container gets a **bind mount** under `/opt/docker/<service>/` — the same convention used for every other service in the stack. Nothing important lives inside a container layer.

| Service | Container path | Host path (bind mount) |
|---|---|---|
| Ollama | `/root/.ollama` | `/opt/docker/ollama/models` |
| Open WebUI | `/app/backend/data` | `/opt/docker/open-webui/data` |
| ComfyUI | `/opt/ComfyUI/models` | `/opt/docker/comfyui/models` |
| ComfyUI | `/opt/ComfyUI/output` | `/opt/docker/comfyui/output` |
| JupyterLab | `/home/jovyan/notebooks` | `/opt/docker/jupyterlab/notebooks` |

If a container is deleted or updated, the data on the host is untouched — `docker compose up -d` re-attaches it. Backup is a plain `rsync` of `/opt/docker/`.

### What Goes on the OS (Host)

- GPU drivers + CUDA toolkit
- NVIDIA Container Toolkit
- Docker Engine
- Host firewall
- LVM / storage mounts
- Netdata (host-level metrics)
- SSH, NTP, systemd

### What Goes in Docker

- Ollama
- Open WebUI
- ComfyUI
- JupyterLab
- LangChain / agent workloads
- Any AI model service or experiment

The one deliberate exception is LM Studio — it runs natively via systemd, not in Docker, because LM Link (its remote-GPU compute layer for the Mac client) needs direct hardware access that's simpler to grant outside a container.

## Deployment Phasing

Building the stack in stages, gating each on a concrete verification step before moving on, kept the debugging surface small at every point:

1. **Stabilize the base** — GPU drivers, CUDA, NVIDIA Container Toolkit, firewall. Gate: `nvidia-smi` and the Docker `nvidia` runtime both work.
2. **Run one model service** — Ollama in Docker with a small starter model set. Gate: a prompt returns a response and VRAM usage shows up in `nvidia-smi`.
3. **Add the interface layer** — Open WebUI (chat) and JupyterLab (GPU-backed notebooks). Gate: both load in-browser and see the GPU.
4. **Choose the model set** — fast general-purpose baseline, a coding model, and a reasoning model, sized to fit comfortably in VRAM before pushing limits.
5. **Automate and integrate** — expose the local LLM via API to other services; add persistent GPU/host monitoring (Prometheus + Grafana).
6. **Experiment with orchestration** — only after the base stack is reliably boring: compare Docker-native model runners, evaluate agent frameworks that sit on top of the inference layer.
7. **Expand if it earns it** — additional GPU capacity only once VRAM limits are actually being hit in practice, not speculatively.

### What to avoid at each stage

- Don't start with agent frameworks before the model service is stable
- Don't chase flagship-sized models on one GPU unless that's specifically the goal
- Don't overbuild the UI layer before the GPU inference path is proven
- Don't pull every interesting model — keep the list curated to what's actually used

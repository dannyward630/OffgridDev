<!--
This file is part of OffgridDev
hardware-and-model-configuration.md
Author(s): Gabriel Mongefranco
Created: 2026-08-06
Last Modified: 2026-08-06
Summary: Documents GPU/VRAM/disk requirements and the config/models.env model-enable
  workflow referenced from the README's Documentation section.
Notes: See README file for documentation and full license information.

Copyright © 2026 The Regents of the University of Michigan

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.
You should have received a copy of the GNU General Public License along
with this program. If not, see <https://www.gnu.org/licenses/>.

-->
![Eisenberg Family Depression Center](https://code.depressioncenter.org/images/EFDCLogo_375w.png "depressioncenter.org")

# Hardware & Model Configuration

[← Back to README](../README.md)

## GPU

A **GPU (Graphics Processing Unit)** accelerates AI workloads. Without one, only very small models are usable.

OffgridDev only supports GPU acceleration on **NVIDIA GPUs**. It runs CPU-only automatically if no NVIDIA GPU
is detected — no configuration needed.

- **Windows / macOS:** Enable GPU support in Docker Desktop's settings, and make sure your NVIDIA driver is
  up to date. No extra install required.
- **Linux, native Docker Engine (not Docker Desktop):** Also install the
  [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html):
  ```
  sudo apt-get install -y nvidia-container-toolkit
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
  ```
  `offgriddev-start.sh` detects this automatically and warns (without failing) if the toolkit isn't configured.

## VRAM

**VRAM** is memory on the GPU. It determines which models you can run.

| VRAM | Practical Models |
|-----:|------------------|
| 4 GB | 3B–7B models |
| 8–12 GB | 7B / MoE models |
| 20+ GB | Large coder / reasoning models |

OffgridDev automatically detects VRAM and blocks invalid configurations.

**Multiple NVIDIA GPUs:** their VRAM is summed for tier purposes (e.g. two 12GB cards qualify for the 24GB
tier), and `docker-compose.gpu.yml` exposes all of them to Ollama so it can split a large model's layers
across cards. Only NVIDIA GPUs count — an integrated Intel/AMD GPU alongside an NVIDIA card is ignored, not
summed in.

## Disk Space Requirements

- **Absolute minimum:** ~12 GB download, plus a fixed ~274 MB for `nomic-embed-text` (see
  [RAG embeddings](troubleshooting.md#rag-embeddings)) — pulled automatically every run regardless of which
  chat models you enable.
- **Recommended:** 24 GB+ for useful coding models

## Model Configuration

Models are controlled in:

```
config/models.env
```

You enable which models to pull — enable as many as you like. The startup script blocks the whole run if
your VRAM can't cover something you enabled, but it does **not** pick a single "best" model for you: every
enabled, VRAM-valid model gets pulled, and you choose which one to actually use per-session (VS Code's
Continue dropdown, or the Open WebUI model switcher — see
[Web Interface](installation-and-usage.md#web-interface)).

Example:
```env
ENABLE_QWEN25_CODER_3B=0
ENABLE_QWEN25_CODER_7B=1
ENABLE_QWEN25_CODER_32B=0
```

Supported families: Qwen 2.5 Coder (0.5B–32B), Qwen3 Coder (30B, MoE), DeepSeek Coder, Gemma 3 / Gemma 4,
and Devstral (24B). Two models were evaluated and intentionally left out:

- **Kimi** — no official, locally-runnable Kimi build is currently published to Ollama's library. The last
  local release (`kimi-k2`) was retired; the newer `kimi-k3` is cloud-only and requires a paid Ollama
  subscription, which conflicts with this project's fully offline design.
- **Qwen3-Coder 480B** — Ollama's other official Qwen3-Coder size, at ~290 GB+ download, is far outside the
  disk/VRAM range any machine this project targets can realistically run.

---

Copyright © 2026 The Regents of the University of Michigan. Licensed under the GNU General Public License
v3.0 or later (software) and the GNU Free Documentation License v1.3 or later (this document). See
[LICENSE](../LICENSE) and [NOTICE](../NOTICE) for full terms.

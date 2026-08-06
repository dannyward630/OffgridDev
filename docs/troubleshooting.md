<!--
This file is part of OffgridDev
troubleshooting.md
Author(s): Gabriel Mongefranco
Created: 2026-08-06
Last Modified: 2026-08-06
Summary: Documents known failure modes and their fixes for the OffgridDev stack,
  referenced from the README's Documentation section.
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

# Troubleshooting

[← Back to README](../README.md)

## Viewing container logs
The startup scripts run everything inside Docker, so failures don't print to your terminal. To see what a
container is actually doing:
```
docker logs offgriddev-webui        # Web UI - one-shot dump
docker logs -f offgriddev-webui     # Web UI - live tail, Ctrl+C to stop
docker logs offgriddev-ollama       # Ollama, same options
```
To check whether a container is currently healthy:
```
docker inspect --format "{{.State.Health.Status}}" offgriddev-webui
```

## A model fails to pull
If a single enabled model can't be pulled — a registry hiccup, a full disk, a tag that's been retired — the
startup scripts print a `WARNING:` for that model and move on to the rest of the list rather than aborting
the whole run. The final "Active models" list (printed once the script finishes) only shows models that
actually pulled; anything that failed is called out separately underneath it, e.g.:
```
Active models:
  - Qwen 2.5 Coder 7B

Failed to pull (not available in Web UI or Continue - see warnings above):
  - Gemma 3 7B
```
The run only stops outright with an `ERROR:` if **every** enabled chat model failed to pull — at that point
there's nothing to chat with, so continuing wouldn't leave you with a usable stack. Scroll back through the
warnings to see why each failure happened, fix that (usually network, disk space, or an outdated tag), and
re-run the startup script — it's safe to run repeatedly.

## Tools errors on DeepSeek Coder / Gemma 3
```
registry.ollama.ai/library/deepseek-coder:6.7b does not support tools
```
This is Ollama's own error, not Open WebUI's — it means a request reached Ollama with a `tools` definition
attached, and the model's template has no way to use one. DeepSeek Coder and Gemma 3 never support Ollama
tool calling, at any size (confirmed against each model's capability tags on ollama.com/library) — this
isn't specific to Sub-agents. Open WebUI defaults every model to attempt **native** (tool-based) function
calling the moment *any* builtin tool is enabled for a request, and **Code Interpreter is enabled by
default** in stock Open WebUI, independent of the
[Sub-agents](installation-and-usage.md#sub-agents) setting.

The startup scripts handle this automatically: after Web UI comes up, they configure DeepSeek Coder and
Gemma 3 (all sizes used by this project) with Function Calling forced to **Legacy** via Open WebUI's Models
API — the one setting that, per Open WebUI's own source, unconditionally skips native tool injection for a
model, regardless of which builtin tool triggered it. This step is non-fatal and silently skipped if you've
turned `WEBUI_AUTH` back on (it signs in as the default admin using a blank password, which only works with
auth disabled).

**If you still see this error after re-running the startup script:** check it manually — open
**Workspace → Models**, edit the model in question, and confirm **Function Calling** reads **Legacy** (not
*Default* — despite the name, *Default* still triggers native tool calls if unset in this version). If it's
not applying, or you hit this on a model not listed above, that's a real bug worth reporting with the exact
request shown in your browser's Network tab (DevTools → Network → the failing `/api/chat/completions` call)
for the `tools` field it's sending — that's the detail needed to track down which feature is attaching it.

## Web UI is slow to start, returns a 500, or restarts itself
The startup scripts wait up to 90 seconds for Open WebUI's own Docker healthcheck to go green before
declaring success or failure — normal startup (loading its embedding model, running DB migrations) is
usually well under 30 seconds, but a fresh/first boot or a slow disk can take longer. If it still isn't
healthy after 90 seconds, check `docker logs offgriddev-webui` (see above) for the actual error rather than
guessing. See [RAG embeddings](#rag-embeddings) below for the Hugging Face network dependency this used to
have and no longer does for RAG specifically.

## RAG embeddings
Open WebUI needs an embedding model to power document/"chat with your files" search. By default it fetches
one (`sentence-transformers/all-MiniLM-L6-v2`) from Hugging Face. This project instead points it at Ollama —
`docker-compose.yml` sets `RAG_EMBEDDING_ENGINE=ollama` and `RAG_EMBEDDING_MODEL=nomic-embed-text`, and the
startup scripts always pull `nomic-embed-text` (~274 MB) into Ollama, matching Open WebUI's own documented
recommendation for air-gapped deployments (`docs.openwebui.com/troubleshooting/rag/`). Actual RAG queries
route through `ollama:11434`, the same connection already used for chat — no Hugging Face involved.

**Caveat, found by testing this directly against a real container, not assumed:** in the current image
(v0.11.0), Open WebUI still loads a small local copy of the Hugging Face embedding model at every boot
regardless of this setting — a known quirk, not something these env vars can fully suppress. This is
harmless once it's cached: `HF_HUB_OFFLINE=1` (still set, belt-and-suspenders) forces it to load from the
local cache with zero network calls, confirmed by grepping a full startup log for any `huggingface.co`
reference and finding none. **What this means in practice:** a machine that has already booted this stack
once needs no internet, ever, for Open WebUI to start — verified. A **completely fresh clone on a brand-new
machine** still needs one working internet connection on its very first boot, to let Open WebUI fetch and
cache that small local copy — there's no way to avoid this without committing ~90 MB of binary model weights
into this git repo, which conflicts with `.gitignore`'s `data/` policy (runtime state, not source) and adds
permanent repo bloat. If you'd rather have byte-for-byte zero-network-ever-including-first-clone at the cost
of that repo size, that's a deliberate tradeoff to make on purpose — ask before assuming it's wanted.

## Models respond correctly but are painfully slow / "is it even using my GPU?"
A GPU can be correctly detected on your machine and passed through to the container and Ollama will *still*
silently fall back to CPU — with no error — if your NVIDIA driver is older than the CUDA build this Ollama
image needs. The startup scripts now check for this automatically after starting containers and print a
warning naming the required driver version if it happens; you can also check by hand at any time:
```
docker inspect --format "{{.State.Health.Status}} " offgriddev-ollama
docker exec offgriddev-ollama ollama ps
```
The `PROCESSOR` column in `ollama ps` reads `100% GPU` when it's working and `100% CPU` when it isn't (only
shows currently-loaded models — run a chat first if the list is empty). If it says CPU and you have an
NVIDIA GPU, update your driver from [nvidia.com/drivers](https://www.nvidia.com/drivers) (search your exact
GPU model), then re-run the startup script. On a University-managed laptop, driver updates may require your
department's IT support if you don't have local admin rights.

## Resetting a stuck container
```
docker compose -f docker/docker-compose.yml down
docker compose -f docker/docker-compose.yml up -d
```
This recreates the containers without touching anything in `data/` (models, chat history, uploads are all
preserved — they live in the bind-mounted `data/` directory, not in the container itself).

---

Copyright © 2026 The Regents of the University of Michigan. Licensed under the GNU General Public License
v3.0 or later (software) and the GNU Free Documentation License v1.3 or later (this document). See
[LICENSE](../LICENSE) and [NOTICE](../NOTICE) for full terms.

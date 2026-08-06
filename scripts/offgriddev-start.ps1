# This file is part of OffgridDev
# offgriddev-start.ps1
# Author(s): Gabriel Mongefranco
# Created: 2026-04-23
# Last Modified: 2026-08-06
# Summary: Windows launcher for the OffgridDev stack. Starts Docker Desktop if needed,
#   detects NVIDIA GPU VRAM to gate which models are safe to run, starts the Ollama/Open
#   WebUI containers, pulls every enabled model from config/models.env, forces legacy
#   function calling on models that don't support Ollama tool calls, and writes VS Code's
#   Continue extension config.
# Notes: See README file for documentation and full license information.
#
# Copyright © 2026 The Regents of the University of Michigan
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along
# with this program. If not, see <https://www.gnu.org/licenses/>.

$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
$Config = Join-Path $Root "config\models.env"

Write-Host "=== OffgridDev ==="
Write-Host "Root: $Root"
Write-Host ""

# Tracks how the script left the try block below, so the `finally` handler can tell a
# normal finish or a deliberate Fail() apart from a Ctrl+C / unexpected interruption and
# only print an extra "Interrupted" message for the latter.
$script:ScriptCompletedNormally = $false
$script:ExpectedExit = $false

function Fail($msg) {
    Write-Host ""
    Write-Error $msg
    Write-Host ""
    Read-Host "Press Enter to exit"
    $script:ExpectedExit = $true
    exit 1
}

# Everything else runs inside this try so Ctrl+C (or any unhandled error) at any point -
# waiting on Docker, pulling images, pulling models - unwinds cleanly through `finally`
# instead of leaving a raw stack trace.
try {

# --------------------------------------------------
# Docker detection, with auto-launch if installed but not running
# --------------------------------------------------

function Test-Docker($cmd) {
    try {
        # Redirect every stream: a not-running daemon makes `docker info` print its own
        # noisy error, and we want our own clean message instead, not raw CLI output.
        & $cmd info *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Find-DockerDesktopExe {
    $Candidates = @(
        "$env:LOCALAPPDATA\Programs\Docker\Docker\Docker Desktop.exe",
        "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    )
    foreach ($Candidate in $Candidates) {
        if (Test-Path $Candidate) {
            return $Candidate
        }
    }
    return $null
}

function Wait-ForDocker($cmd, [int]$TimeoutSeconds) {
    $Elapsed = 0
    $Interval = 2
    Write-Host "Waiting for Docker Desktop to start..." -NoNewline
    while ($Elapsed -lt $TimeoutSeconds) {
        Start-Sleep -Seconds $Interval
        $Elapsed += $Interval
        if (Test-Docker $cmd) {
            Write-Host " ready."
            return $true
        }
        Write-Host "." -NoNewline
    }
    Write-Host ""
    return $false
}

# Resolve a docker.exe path: PATH first, then the common per-user / system-wide Docker
# Desktop install locations.
$Docker = $null

if (Get-Command "docker" -ErrorAction SilentlyContinue) {
    $Docker = "docker"
} else {
    $UserDocker = "$env:LOCALAPPDATA\Programs\Docker\Docker\resources\bin\docker.exe"
    $SystemDocker = "C:\Program Files\Docker\Docker\resources\bin\docker.exe"
    if (Test-Path $UserDocker) {
        $Docker = $UserDocker
    } elseif (Test-Path $SystemDocker) {
        $Docker = $SystemDocker
    }
}

if (-not $Docker) {
    Fail "Docker Desktop is not installed. Install it from https://www.docker.com/products/docker-desktop, then re-run this script."
}

if (-not (Test-Docker $Docker)) {
    # docker.exe exists but the daemon isn't responding - Docker Desktop is closed.
    # Try to launch it and wait briefly rather than failing immediately.
    $DesktopExe = Find-DockerDesktopExe
    if ($DesktopExe) {
        Write-Host "Docker Desktop is not running. Launching it..."
        Start-Process -FilePath $DesktopExe | Out-Null
        if (-not (Wait-ForDocker $Docker 60)) {
            Fail "Docker Desktop did not become ready within 60 seconds. Start it manually, wait until it says 'Docker Desktop is running', then re-run this script."
        }
    } else {
        Fail "Docker Desktop is installed but not running, and it could not be launched automatically (Docker Desktop.exe not found). Start it manually, wait until it is ready, then re-run this script."
    }
}

# --------------------------------------------------
# Detect GPU VRAM (MB)
# --------------------------------------------------

function Get-NvidiaSmiPath {
    if (Get-Command "nvidia-smi" -ErrorAction SilentlyContinue) {
        return "nvidia-smi"
    }
    $SystemNvidiaSmi = "C:\Windows\System32\nvidia-smi.exe"
    if (Test-Path $SystemNvidiaSmi) {
        return $SystemNvidiaSmi
    }
    return $null
}

$NvidiaSmi = Get-NvidiaSmiPath
$VramMb = 0
$GpuCount = 0

if ($NvidiaSmi) {
    try {
        # nvidia-smi prints one line per NVIDIA GPU ("<name>, <VRAM MiB>"). Enumerate and
        # sum all of them: docker-compose.gpu.yml requests every NVIDIA GPU (count: all),
        # and Ollama can split a model's layers across multiple cards. This intentionally
        # only sees NVIDIA devices — integrated/other-vendor GPUs never appear here.
        $SmiLines = & $NvidiaSmi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null
        foreach ($line in $SmiLines) {
            $Parts = $line -split ",\s*"
            if ($Parts.Count -ge 2) {
                $GpuName = $Parts[0].Trim()
                $GpuVram = [int]($Parts[1].Trim())
                Write-Host "Detected GPU: $GpuName ($GpuVram MB)"
                $VramMb += $GpuVram
                $GpuCount++
            }
        }
    } catch {
        Write-Host "WARNING: Could not query GPU VRAM. Treating as CPU-only system."
        $VramMb = 0
        $GpuCount = 0
    }
} else {
    Write-Host "WARNING: nvidia-smi not found. Treating as CPU-only system."
}

if ($VramMb -gt 0) {
    if ($GpuCount -gt 1) {
        Write-Host "Combined GPU VRAM across $GpuCount NVIDIA GPUs: $VramMb MB"
    } else {
        Write-Host "Detected GPU VRAM: $VramMb MB"
    }
    if ($VramMb -lt 6000) {
        Write-Host "GPU tier: LOW VRAM (<= 6 GB)"
    } elseif ($VramMb -lt 12000) {
        Write-Host "GPU tier: MID VRAM (6-12 GB)"
    } else {
        Write-Host "GPU tier: HIGH VRAM (12+ GB)"
    }
} else {
    Write-Host "GPU tier: NONE / CPU-only"
}
Write-Host ""

# --------------------------------------------------
# Create data directories
# --------------------------------------------------

New-Item -ItemType Directory -Force (Join-Path $Root "data\ollama") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Root "data\open-webui") | Out-Null

# --------------------------------------------------
# Load config
# --------------------------------------------------

if (-not (Test-Path $Config)) {
    Fail "Missing config\models.env"
}

Get-Content $Config | ForEach-Object {
    if ($_ -match "^(ENABLE_\w+)=(\d)") {
        Set-Variable -Name $matches[1] -Value $matches[2]
    }
}

# --------------------------------------------------
# Enforce sane model selection by VRAM
# --------------------------------------------------

if ($VramMb -lt 6000) {
    if ($ENABLE_QWEN25_CODER_0P5B -ne "1" -and $ENABLE_QWEN25_CODER_1P5B -ne "1" -and
        $ENABLE_QWEN25_CODER_3B -ne "1" -and $ENABLE_QWEN25_CODER_7B -ne "1") {
        Fail "GPU has $VramMb MB VRAM. Enable a Qwen 2.5 Coder 0.5B/1.5B/3B/7B model in models.env."
    }
    if ($ENABLE_QWEN25_CODER_14B -eq "1") {
        Fail "14B models require ~10 GB VRAM. Your GPU has $VramMb MB."
    }
    if ($ENABLE_QWEN25_CODER_32B -eq "1") {
        Fail "32B models require ~20 GB VRAM. Your GPU has $VramMb MB."
    }
    if ($ENABLE_GEMMA4_E4B -eq "1") {
        Fail "Gemma4 E4B requires ~6-8 GB VRAM. Your GPU has $VramMb MB."
    }
}

if ($VramMb -lt 12000) {
    if ($ENABLE_QWEN25_CODER_32B -eq "1") {
        Fail "32B models require ~20 GB VRAM. Your GPU has $VramMb MB."
    }
    if ($ENABLE_QWEN3_CODER_30B -eq "1") {
        Fail "Qwen3 Coder 30B requires ~20 GB VRAM. Your GPU has $VramMb MB."
    }
    if ($ENABLE_DEVSTRAL_24B -eq "1") {
        Fail "Devstral 24B requires ~16 GB VRAM. Your GPU has $VramMb MB."
    }
    if ($ENABLE_DEEPSEEK_CODER_33B -eq "1") {
        Fail "DeepSeek 33B requires ~20 GB VRAM. Your GPU has $VramMb MB."
    }
    if ($ENABLE_GEMMA4_26B_A4B -eq "1") {
        Fail "Gemma4 26B A4B requires ~10-12 GB VRAM. Your GPU has $VramMb MB."
    }
}

# --------------------------------------------------
# Start containers (GPU override attached only if a GPU was detected)
# --------------------------------------------------

$DockerDir = Join-Path $Root "docker"
if (-not (Test-Path $DockerDir)) {
    Fail "Missing docker directory"
}

# Compose files are referenced by absolute path instead of `cd`-ing into $DockerDir:
# Set-Location changes are process-wide in PowerShell (not scoped to this script), so a
# `cd` here would leave the user's own shell sitting in docker\ after the script exits.
$ComposeArgs = @("-f", (Join-Path $DockerDir "docker-compose.yml"))
if ($VramMb -gt 0) {
    $ComposeArgs += @("-f", (Join-Path $DockerDir "docker-compose.gpu.yml"))
}

& $Docker compose @ComposeArgs pull
& $Docker compose @ComposeArgs up -d

# --------------------------------------------------
# Verify the GPU override actually got used, not just requested
# --------------------------------------------------
# A GPU can be correctly detected and passed through to the container and Ollama will
# still silently fall back to CPU if the host's NVIDIA driver is older than the CUDA
# build this Ollama image needs - there's no error, just a much slower model that looks
# identical from the outside. Ollama logs this at startup, so check for it here instead
# of leaving the user to notice only because everything feels slow.
if ($VramMb -gt 0) {
    Start-Sleep -Seconds 2
    $OllamaStartupLogs = (& $Docker logs offgriddev-ollama) -join "`n"
    if ($OllamaStartupLogs -match 'NVIDIA driver too old"\s+device="([^"]+)"[^\n]*required_driver="([^"]+)"') {
        Write-Host ""
        Write-Host "WARNING: GPU detected ($($Matches[1])), but its NVIDIA driver is too old for this"
        Write-Host "  Ollama build (needs driver $($Matches[2])). Falling back to CPU - models will work"
        Write-Host "  but run much slower. Update the driver from https://www.nvidia.com/drivers, then"
        Write-Host "  re-run this script."
        Write-Host ""
    }
}

# --------------------------------------------------
# Pull enabled models
# --------------------------------------------------
# A pull can fail for reasons the VRAM gate above never checks - a registry hiccup, a
# full disk, a tag that's been retired - and previously any single failure called Fail()
# and killed the whole run, leaving every *other* enabled model unpulled too. Each
# failure is now reported and skipped instead, so the run keeps going through the rest of
# the list. Only the chat models (not the mandatory RAG embedding model below) count
# toward the "did anything usable come out of this" check right after the loop - if none
# of them pulled, there's nothing to chat with and the run stops there instead of handing
# the user a Web UI with an empty model list and no explanation.

$script:ChatModelsRequested = 0
$script:ChatModelsPulled = 0
$script:PulledChatModelLabels = @()
$script:FailedChatModelLabels = @()

function Pull-Model($model, $label, [bool]$IsChatModel = $true) {
    if ($IsChatModel) { $script:ChatModelsRequested++ }
    try {
        & $Docker exec -it offgriddev-ollama ollama pull $model
        if ($LASTEXITCODE -ne 0) {
            throw "ollama pull exited with code $LASTEXITCODE"
        }
        if ($IsChatModel) {
            $script:ChatModelsPulled++
            $script:PulledChatModelLabels += $label
        }
    } catch {
        Write-Host ""
        Write-Host "WARNING: Failed to pull $label ($model). Skipping it and continuing with the remaining models."
        Write-Host "  $_"
        Write-Host ""
        if ($IsChatModel) { $script:FailedChatModelLabels += $label }
    }
}

# Always pulled, regardless of which chat models are enabled: docker-compose.yml points
# Open WebUI's RAG embeddings at this model over Ollama (RAG_EMBEDDING_ENGINE=ollama)
# instead of the default Hugging Face download, so it needs to already exist here before
# Open WebUI's first request for it - not a user-selectable chat model, so it's not
# gated behind an ENABLE_ flag in models.env, and its failure doesn't count against the
# "at least one chat model must succeed" check below (RAG degrades; chat still works).
Pull-Model "nomic-embed-text" "Nomic Embed Text (RAG embedding model)" $false

if ($ENABLE_QWEN25_CODER_0P5B -eq 1) {
    Pull-Model "qwen2.5-coder:0.5b" "Qwen 2.5 Coder 0.5B"
}

if ($ENABLE_QWEN25_CODER_1P5B -eq 1) {
    Pull-Model "qwen2.5-coder:1.5b" "Qwen 2.5 Coder 1.5B"
}

if ($ENABLE_QWEN25_CODER_3B -eq 1) {
    Pull-Model "qwen2.5-coder:3b" "Qwen 2.5 Coder 3B"
}

if ($ENABLE_QWEN25_CODER_7B -eq 1) {
    Pull-Model "qwen2.5-coder:7b" "Qwen 2.5 Coder 7B"
}

if ($ENABLE_QWEN25_CODER_14B -eq 1) {
    Pull-Model "qwen2.5-coder:14b" "Qwen 2.5 Coder 14B"
}

if ($ENABLE_QWEN25_CODER_32B -eq 1) {
    Pull-Model "qwen2.5-coder:32b" "Qwen 2.5 Coder 32B"
}

if ($ENABLE_QWEN3_CODER_30B -eq 1) {
    Pull-Model "qwen3-coder:30b" "Qwen3 Coder 30B"
}

if ($ENABLE_DEVSTRAL_24B -eq 1) {
    Pull-Model "devstral:24b" "Devstral 24B"
}

if ($ENABLE_DEEPSEEK_CODER_1P3B -eq 1) {
    Pull-Model "deepseek-coder:1.3b" "DeepSeek Coder 1.3B"
}

if ($ENABLE_DEEPSEEK_CODER_6P7B -eq 1) {
    Pull-Model "deepseek-coder:6.7b" "DeepSeek Coder 6.7B"
}

if ($ENABLE_DEEPSEEK_CODER_33B -eq 1) {
    Pull-Model "deepseek-coder:33b" "DeepSeek Coder 33B"
}

if ($ENABLE_GEMMA3_2B -eq 1) {
    Pull-Model "gemma3:2b" "Gemma 3 2B"
}

if ($ENABLE_GEMMA3_7B -eq 1) {
    Pull-Model "gemma3:7b" "Gemma 3 7B"
}

if ($ENABLE_GEMMA4_E4B -eq 1) {
    Pull-Model "gemma4:e4b" "Gemma 4 E4B"
}

if ($ENABLE_GEMMA4_26B_A4B -eq 1) {
    Pull-Model "gemma4:26b-a4b" "Gemma 4"
}

if ($ChatModelsRequested -gt 0 -and $ChatModelsPulled -eq 0) {
    Fail "All $ChatModelsRequested enabled chat model(s) failed to pull. See the warnings above for why, fix the underlying issue (network, disk space, registry), then re-run this script."
}
if ($ChatModelsPulled -lt $ChatModelsRequested) {
    Write-Host "NOTE: $ChatModelsPulled of $ChatModelsRequested enabled chat models pulled successfully. Continuing with those."
    Write-Host ""
}

# --------------------------------------------------
# Health check
# --------------------------------------------------
# Polls the container's own Docker healthcheck instead of firing one HTTP request right
# after `up -d`: Open WebUI's first-boot init (loading its embedding model, running DB
# migrations) routinely takes 15-30+ seconds, so a single immediate request almost always
# hit it mid-startup and failed the whole script even though the container was fine.

function Wait-ForWebUI([int]$TimeoutSeconds) {
    $Elapsed = 0
    $Interval = 3
    Write-Host "Waiting for Web UI to finish starting..." -NoNewline
    while ($Elapsed -lt $TimeoutSeconds) {
        $HealthStatus = & $Docker inspect --format "{{.State.Health.Status}}" offgriddev-webui 2>$null
        if ($HealthStatus -eq "healthy") {
            Write-Host " ready."
            return $true
        }
        Start-Sleep -Seconds $Interval
        $Elapsed += $Interval
        Write-Host "." -NoNewline
    }
    Write-Host ""
    return $false
}

if (-not (Wait-ForWebUI 90)) {
    Fail "Web UI did not report healthy within 90 seconds. Check its logs: docker logs offgriddev-webui"
}

# --------------------------------------------------
# Configure non-tool-capable models to skip native function calling
# --------------------------------------------------
# DeepSeek Coder and Gemma 3 don't support Ollama's tool-calling capability at all, but Open
# WebUI defaults every model to attempt native tool calls whenever a builtin tool (Code
# Interpreter, Sub-agents, etc.) is enabled for the request - Ollama then rejects every
# message for these models with "does not support tools". Setting each one's Function
# Calling param to "legacy" here (equivalent to Workspace -> Models -> Edit -> Function
# Calling -> Legacy in the UI) makes Open WebUI fall back to prompt-based tool use instead,
# which these models do support. Non-fatal and silently skipped if WEBUI_AUTH has been
# turned back on, since the blank-password sign-in this relies on only works with auth off.
$NonToolCapableModels = @(
    @{ id = "deepseek-coder:1.3b"; name = "DeepSeek Coder 1.3B" },
    @{ id = "deepseek-coder:6.7b"; name = "DeepSeek Coder 6.7B" },
    @{ id = "deepseek-coder:33b";  name = "DeepSeek Coder 33B" },
    @{ id = "gemma3:2b";           name = "Gemma 3 2B" },
    @{ id = "gemma3:7b";           name = "Gemma 3 7B" }
)
try {
    $SignIn = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/auths/signin" -Method Post `
        -ContentType "application/json" -Body '{"email":"admin@localhost","password":""}' -ErrorAction Stop
    $AuthHeaders = @{ Authorization = "Bearer $($SignIn.token)" }
    foreach ($ModelEntry in $NonToolCapableModels) {
        $Payload = @{
            id = $ModelEntry.id
            base_model_id = $ModelEntry.id
            name = $ModelEntry.name
            meta = @{}
            params = @{ function_calling = "legacy" }
            is_active = $true
        } | ConvertTo-Json -Depth 5
        try {
            Invoke-RestMethod -Uri "http://localhost:3000/api/v1/models/create" -Method Post `
                -ContentType "application/json" -Headers $AuthHeaders -Body $Payload -ErrorAction Stop | Out-Null
        } catch {
            # Most likely this model ID already exists (e.g. re-running this script, or a
            # manual edit in the UI left it misconfigured) - fall back to updating it in
            # place so the fix still applies. Failure here is non-fatal either way.
            try {
                Invoke-RestMethod -Uri "http://localhost:3000/api/v1/models/model/update" -Method Post `
                    -ContentType "application/json" -Headers $AuthHeaders -Body $Payload -ErrorAction Stop | Out-Null
            } catch {}
        }
    }
} catch {
    Write-Host "NOTE: Could not auto-configure DeepSeek Coder / Gemma 3 for tool compatibility (Open WebUI auth may be enabled). See README's Troubleshooting section to do it manually."
}

# --------------------------------------------------
# Write Continue (VS Code) config
# --------------------------------------------------

$ContinueDir = Join-Path $env:USERPROFILE ".continue"
$ContinueConfig = Join-Path $ContinueDir "config.yaml"

New-Item -ItemType Directory -Force $ContinueDir | Out-Null

@"
name: OffgridDev
version: 0.0.1
schema: v1
models:
  - name: OffgridDev Autodetect
    provider: ollama
    model: AUTODETECT
    apiBase: http://localhost:11434
    roles:
      - chat
      - edit
      - apply
      - rerank
      - autocomplete
"@ | Set-Content -Path $ContinueConfig -Encoding utf8

Write-Host "Continue config written to:"
Write-Host $ContinueConfig
Write-Host ""

# --------------------------------------------------
# Success
# --------------------------------------------------

Write-Host ""
Write-Host "OffgridDev READY"
Write-Host "Web UI: http://localhost:3000"
Write-Host "API   : http://localhost:11434"
Write-Host ""
# Reflects what actually pulled, not just what was enabled in models.env - a model that
# failed above (see warnings) is not silently reported as available here.
Write-Host "Active models:"
if ($PulledChatModelLabels.Count -eq 0) {
    Write-Host "  (none)"
} else {
    foreach ($ModelLabel in $PulledChatModelLabels) { Write-Host "  - $ModelLabel" }
}
if ($FailedChatModelLabels.Count -gt 0) {
    Write-Host ""
    Write-Host "Failed to pull (not available in Web UI or Continue - see warnings above):"
    foreach ($ModelLabel in $FailedChatModelLabels) { Write-Host "  - $ModelLabel" }
}
Write-Host ""
Write-Host "#NoTokens"
Write-Host ""
Read-Host "Press Enter to exit"

$script:ScriptCompletedNormally = $true

} finally {
    if (-not $script:ScriptCompletedNormally -and -not $script:ExpectedExit) {
        Write-Host ""
        Write-Host "Interrupted - stopping."
    }
}

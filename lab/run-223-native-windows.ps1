# Real-hardware runner for Sybil #223. No synthetic evidence is generated.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$branch = "bounty-223-radeon-890m-128k-candidate"
$root = Join-Path $env:LOCALAPPDATA "Sybil223"
$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$repoDir = Join-Path $root "repo-$stamp"
$modelDir = Join-Path $root "models"
$binRoot = Join-Path $root "llama-vulkan"
$ev = Join-Path $root "evidence-$stamp"
New-Item -ItemType Directory -Force -Path $root, $modelDir, $binRoot, $ev | Out-Null
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "Install Git for Windows first." }
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { throw "Install Python 3 first." }

$gpus = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, AdapterRAM)
$gpu = $gpus | Where-Object { $_.Name -match "Radeon.*890M|890M" } | Select-Object -First 1
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$disk = Get-PSDrive -Name ([IO.Path]::GetPathRoot($root).Substring(0,1))
$probe = [ordered]@{ captured_utc=(Get-Date).ToUniversalTime().ToString("o"); os=$os.Caption; os_version=$os.Version; cpu=(Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name); logical_processors=$cs.NumberOfLogicalProcessors; physical_memory_bytes=[int64]$cs.TotalPhysicalMemory; free_memory_bytes=[int64]$os.FreePhysicalMemory*1024; free_disk_bytes=[int64]$disk.Free; video_controllers=$gpus; target_gpu=$(if ($gpu) {$gpu.Name} else {$null}) }
$probe | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $ev "probe-windows.json")
if (-not $gpu) { throw "STOP: Windows did not report Radeon 890M. Probe saved to $ev; no model test started." }
if ($disk.Free -lt 12GB) { throw "STOP: less than 12 GB free disk space. Probe saved to $ev." }

$rel = @(Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=1" -Headers @{ "User-Agent"="sybil-223-runner" })[0]
$asset = $rel.assets | Where-Object { $_.name -match "^llama-b\d+-bin-win-vulkan-x64\.zip$" } | Select-Object -First 1
if (-not $asset) { throw "No official Windows Vulkan x64 build found." }
$zip = Join-Path $root $asset.name
if (-not (Test-Path $zip)) { Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -TimeoutSec 1800 }
$extract = Join-Path $binRoot $rel.tag_name
if (-not (Test-Path $extract)) { Expand-Archive -Path $zip -DestinationPath $extract -Force }
$server = Get-ChildItem $extract -Filter "llama-server.exe" -Recurse | Select-Object -First 1
if (-not $server) { throw "llama-server.exe not found in the official release ZIP." }
$devices = (& $server.FullName --list-devices 2>&1 | Out-String)
$devices | Set-Content -Encoding UTF8 (Join-Path $ev "vulkan-devices.txt")
if ($devices -notmatch "890M") { throw "STOP: llama.cpp Vulkan did not expose Radeon 890M. No inference started; see $ev\vulkan-devices.txt" }
$deviceLine = ($devices -split "\r?\n" | Where-Object { $_ -match "Vulkan\d+.*890M|890M.*Vulkan\d+" } | Select-Object -First 1)
$deviceMatch = [regex]::Match([string]$deviceLine, "Vulkan\d+")
if (-not $deviceMatch.Success) { throw "Could not parse Vulkan device ID; inspect $ev\vulkan-devices.txt." }
$deviceId = $deviceMatch.Value

$model = "Qwen3.5-9B-Q4_K_M.gguf"
$modelPath = Join-Path $modelDir $model
$modelUrl = "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/3885219b6810b007914f3a7950a8d1b469d598a5/$model?download=true"
if (-not (Test-Path $modelPath) -or (Get-Item $modelPath).Length -lt 1000000000) {
  Write-Host "Downloading pinned Qwen3.5-9B GGUF (~5.7 GB)..."
  Invoke-WebRequest -Uri $modelUrl -OutFile $modelPath -TimeoutSec 7200
}
@("llama.cpp release: $($rel.tag_name)"; "asset: $($asset.name)"; "asset_sha256: $((Get-FileHash $zip -Algorithm SHA256).Hash)"; "server_sha256: $((Get-FileHash $server.FullName -Algorithm SHA256).Hash)"; "model: unsloth/Qwen3.5-9B-GGUF@3885219b6810b007914f3a7950a8d1b469d598a5"; "model_sha256: $((Get-FileHash $modelPath -Algorithm SHA256).Hash)"; "Vulkan device: $deviceLine") | Set-Content -Encoding UTF8 (Join-Path $ev "runtime-manifest.txt")

git clone --quiet --single-branch --branch $branch "https://github.com/1132dadf/local-ai-registry.git" $repoDir
if ($LASTEXITCODE -ne 0) { throw "git clone failed." }

$memwatch = Join-Path $ev "memwatch-windows.csv"
$monitor = Start-Job -ArgumentList $memwatch -ScriptBlock {
  param($out)
  "utc,available_ram_gb,cpu_load_pct" | Set-Content -Encoding UTF8 $out
  while ($true) {
    $ts=(Get-Date).ToUniversalTime().ToString("o"); $ram=""; $cpu=""
    try { $o=Get-CimInstance Win32_OperatingSystem; $ram=[math]::Round(([double]$o.FreePhysicalMemory * 1KB / 1GB),3) } catch {}
    try { $cpu=[math]::Round((Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average,1) } catch {}
    "$ts,$ram,$cpu" | Add-Content -Encoding UTF8 $out
    Start-Sleep -Seconds 1
  }
}
$serverOut = Join-Path $ev "llama-server.stdout.log"
$serverErr = Join-Path $ev "llama-server.stderr.log"
$q = [string][char]34
$serverArgsLine = @("-m", "$q$modelPath$q", "--host", "127.0.0.1", "--port", "8080", "--ctx-size", "131072", "--n-gpu-layers", "999", "-b", "512", "-ub", "512", "-t", "4", "--parallel", "1", "--cont-batching", "--poll", "0", "--flash-attn", "on", "--kv-unified", "--cache-type-k", "q4_0", "--cache-type-v", "q4_0", "--jinja", "--reasoning-format", "deepseek", "--metrics", "--device", $deviceId) -join " "
$proc = $null
$labExit = 999
try {
  $proc = Start-Process -FilePath $server.FullName -ArgumentList $serverArgsLine -WorkingDirectory $server.DirectoryName -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr -PassThru
  $ready=$false
  for ($i=0; $i -lt 600; $i++) {
    if ($proc.HasExited) { throw "llama-server exited before healthy; inspect logs in $ev." }
    try { $null=Invoke-RestMethod -Uri "http://127.0.0.1:8080/health" -TimeoutSec 5; $ready=$true; break } catch { Start-Sleep -Seconds 2 }
  }
  if (-not $ready) { throw "llama-server did not become healthy within 20 minutes; inspect logs in $ev." }
  Push-Location $repoDir
  try {
    $labArgs = @("lab/lab.py", "try", "unsloth/Qwen3.5-9B-GGUF@3885219b6810b007914f3a7950a8d1b469d598a5", "--model", "qwen3.5-9b", "--engine", "llama.cpp-vulkan-qwen3.5-9b-q4-k-m-128k", "--card", "radeon-890m-48gb", "--on", "endpoint", "--endpoint", "http://127.0.0.1:8080", "--gpu", $gpu.Name)
    & python @labArgs 2>&1 | Tee-Object -FilePath (Join-Path $ev "lab-try.log")
    $labExit = $LASTEXITCODE
  } finally { Pop-Location }
} finally {
  if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
  Stop-Job $monitor -ErrorAction SilentlyContinue
  Receive-Job $monitor -ErrorAction SilentlyContinue | Out-Null
  Remove-Job $monitor -Force -ErrorAction SilentlyContinue
}

$runFile = Get-ChildItem (Join-Path $repoDir "lab/runs") -Filter "radeon-890m-48gb.*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$passed = $false
if ($runFile) {
  Copy-Item $runFile.FullName (Join-Path $ev "lab-run.json") -Force
  try {
    $run = Get-Content -Raw $runFile.FullName | ConvertFrom-Json
    $gateProps = @($run.evidence.ok.PSObject.Properties | Where-Object { $_.Name -in @("load","chat","reasoning","tools","context","speed") })
    $allSix = ($gateProps.Count -eq 6) -and (@($gateProps | Where-Object { $_.Value -ne $true }).Count -eq 0)
    $passed = ($run.passed -eq $true) -and $allSix -and ([double]$run.proof.tps -ge 15)
  } catch { $passed = $false }
}
@("Target GPU: $($gpu.Name)"; "Vulkan device: $deviceId"; "lab.py exit code: $labExit"; "All six gates true and TPS >= 15: $passed"; "probe-windows.json and memwatch-windows.csv are native Windows diagnostics, not the Linux recipe-kit probe.py/memwatch.sh output."; "No values were edited or replaced with estimates.") | Set-Content -Encoding UTF8 (Join-Path $ev "README.txt")
$zipOut = Join-Path $root "sybil223-evidence-$stamp.zip"
Compress-Archive -Path (Join-Path $ev "*") -DestinationPath $zipOut -Force

if (-not $passed) { Write-Host "NOT PASSED; no recipe/PR was submitted. Evidence archive: $zipOut"; exit 1 }
$dest = Join-Path $repoDir "docs/evidence/sybil223-$stamp"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item (Join-Path $ev "*") $dest -Recurse -Force
Push-Location $repoDir
try {
  git add lab/runs registry/recipes docs/evidence
  if ($LASTEXITCODE -ne 0) { throw "git add failed" }
  git config user.name "1132dadf"
  git config user.email "1132dadf@users.noreply.github.com"
  git commit -m "lab: record Radeon 890M 128K six-gate run for #223"
  if ($LASTEXITCODE -ne 0) { throw "git commit failed" }
  git push origin $branch
  if ($LASTEXITCODE -ne 0) { Write-Host "Six gates passed but push failed. Upload this archive: $zipOut"; exit 2 }
} finally { Pop-Location }
Write-Host "PASS: six gates and >=15 tok/s; evidence pushed to fork branch $branch"
Write-Host "Evidence archive: $zipOut"

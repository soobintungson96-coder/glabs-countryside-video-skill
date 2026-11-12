<#
Resumable batch generator for storyboard shots via G-Labs (meta_muse video).

  .\run_shots.ps1 -ProjectDir <OUTPUT_ROOT\slug> -Act A1 [-MaxInFlight 5] [-TimeoutMin 60]
  .\run_shots.ps1 -ProjectDir <...> -Ids scene_005,scene_009

State lives in project\job_manifest.json (no secrets). Shots already GENERATED/ACCEPTED are skipped.
Each finished clip is downloaded to scenes\<id>.mp4 (never overwritten), probed with ffmpeg,
and 3 QC frames are written to logs\qc\<id>_{start,mid,end}.jpg.
One automatic retry for transient failures; CONTENT_POLICY failures are not retried (prompt needs editing).
#>
param(
    [Parameter(Mandatory = $true)][string]$ProjectDir,
    [string]$Act,
    [string[]]$Ids,
    [int]$MaxInFlight = 5,
    [int]$TimeoutMin = 60,
    [int]$VideoLength = 8,
    [int]$PollSec = 15
)
$ErrorActionPreference = 'Stop'
$glabs = Join-Path $PSScriptRoot 'glabs.ps1'
$ff = 'C:\Users\Admin\AppData\Local\Programs\G-Labs Studio\bin\ffmpeg\win\ffmpeg.exe'
$proj = Join-Path $ProjectDir 'project'
$plan = Get-Content -Raw -Encoding UTF8 (Join-Path $proj 'canonical_payload.json') | ConvertFrom-Json
$manifestPath = Join-Path $proj 'job_manifest.json'
$logPath = Join-Path $ProjectDir 'logs\generation_log.jsonl'
New-Item -ItemType Directory -Force (Join-Path $ProjectDir 'scenes'), (Join-Path $ProjectDir 'logs\qc'), (Join-Path $proj 'requests') | Out-Null

$manifest = @{}
if (Test-Path $manifestPath) {
    (Get-Content -Raw -Encoding UTF8 $manifestPath | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $manifest[$_.Name] = $_.Value }
}
function Save-Manifest {
    $o = [ordered]@{}; foreach ($k in ($manifest.Keys | Sort-Object)) { $o[$k] = $manifest[$k] }
    [IO.File]::WriteAllText($manifestPath, ($o | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
}
function Write-Log($obj) {
    $obj['ts'] = (Get-Date).ToString('s')
    Add-Content -Encoding UTF8 $logPath (($obj | ConvertTo-Json -Compress -Depth 6))
}
function Invoke-FF([string]$argLine) {
    # ffmpeg writes info to stderr; run through cmd so PowerShell never turns it into a terminating error
    cmd /c "`"$ff`" $argLine 2>&1" | Out-String
}
function Save-QcFrames([string]$file, [string]$id) {
    $info = Invoke-FF "-hide_banner -i `"$file`""
    $len = if ($info -match 'Duration: (\d+:\d+:[\d.]+)') { [TimeSpan]::Parse($Matches[1]).TotalSeconds } else { 8 }
    foreach ($q in @(@('start', 0.4), @('mid', [Math]::Round($len / 2, 2)), @('end', [Math]::Max(0, $len - 0.6)))) {
        $out = Join-Path $ProjectDir "logs\qc\$($id)_$($q[0]).jpg"
        $null = Invoke-FF "-hide_banner -loglevel error -y -ss $($q[1]) -i `"$file`" -frames:v 1 `"$out`""
    }
    $info
}
$Ids = @($Ids | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
# Fast in-process status polling (no child PowerShell per check); key read from .env.glabs, never printed
$glabsBase = 'http://127.0.0.1:8765'; $glabsKey = $env:GLABS_API_KEY
$dir = (Resolve-Path $ProjectDir).Path
while ($dir -and -not $glabsKey) {
    $envFile = Join-Path $dir '.env.glabs'
    if (Test-Path $envFile) {
        foreach ($line in Get-Content -Encoding UTF8 $envFile) {
            if ($line -match '^\s*GLABS_API_KEY\s*=\s*(.+?)\s*$') { $glabsKey = $Matches[1] }
            if ($line -match '^\s*GLABS_BASE_URL\s*=\s*(.+?)\s*$') { $glabsBase = $Matches[1].TrimEnd('/') }
        }
    }
    $dir = Split-Path $dir -Parent
}
function Get-TaskStatus([string]$tid) {
    if ($glabsKey) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Uri "$glabsBase/api/status/$tid" -Headers @{ 'X-API-Key' = $glabsKey }
            return ([Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json)
        } catch { }
    }
    Invoke-G @('status', '-TaskId', $tid)
}
function Invoke-G([string[]]$a) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $glabs @a 2>&1 | Out-String
    $i = $out.IndexOf('{'); $k = $out.IndexOf('[')
    if ($k -ge 0 -and ($i -lt 0 -or $k -lt $i)) { $i = $k }
    if ($i -lt 0) { throw "glabs.ps1 $($a -join ' ') returned no JSON: $out" }
    $out.Substring($i) | ConvertFrom-Json
}

$targets = @($plan.shots | Where-Object {
        ($Ids -and $_.id -in $Ids) -or ((-not $Ids) -and $Act -and $_.purpose -like "$Act*")
    })
if (-not $targets) { throw 'No shots selected (use -Act or -Ids).' }
$queue = New-Object System.Collections.Queue
$inFlight = @{}   # task_id -> shot
$attempts = @{}
foreach ($s in $targets) {
    $m = $manifest[$s.id]
    if ($m -and $m.status -in @('GENERATED', 'ACCEPTED')) { Write-Host "skip $($s.id) ($($m.status))"; continue }
    if ($m -and $m.status -eq 'FAILED_POLICY' -and -not ($Ids -and $s.id -in $Ids)) { Write-Host "skip $($s.id) (FAILED_POLICY - fix prompt, rerun with -Ids)"; continue }
    if ($m -and $m.status -eq 'RUNNING' -and $m.task_id) {
        # Resume: adopt the task that is still running in G-Labs instead of paying for a new one
        $inFlight[$m.task_id] = $s; $attempts[$s.id] = [int]$m.attempts; Write-Host "resume $($s.id) <- $($m.task_id)"; continue
    }
    if ($m) { $attempts[$s.id] = [int]$m.attempts }
    $queue.Enqueue($s)
}
Write-Host "to generate: $($queue.Count) new, $($inFlight.Count) resumed"
$deadline = (Get-Date).AddMinutes($TimeoutMin)

function Submit-Shot($s) {
    $prompt = "$($s.image_prompt) Motion: $($s.video_prompt) Sound: $($s.audio_prompt)"
    $body = [ordered]@{ prompt = $prompt; model = 'meta_muse'; mode = 'image_to_video'; aspect_ratio = '16:9'; count = 1; video_length = $VideoLength
        reference_images = @($s.reference_ids | ForEach-Object { 'file:' + (Join-Path $ProjectDir "references\$_.jpg") }) }
    foreach ($r in $s.reference_ids) { if (-not (Test-Path (Join-Path $ProjectDir "references\$r.jpg"))) { throw "Missing reference image $r for $($s.id)" } }
    $f = Join-Path $proj "requests\$($s.id).json"
    [IO.File]::WriteAllText($f, ($body | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    $t = Invoke-G @('submit', '-Endpoint', 'video', '-BodyFile', $f)
    $attempts[$s.id] = 1 + [int]$attempts[$s.id]
    $inFlight[$t.task_id] = $s
    $manifest[$s.id] = [pscustomobject]@{ status = 'RUNNING'; task_id = $t.task_id; attempts = $attempts[$s.id]; file = $null; error = $null; model = 'meta_muse' }
    Save-Manifest; Write-Log @{ event = 'submit'; shot = $s.id; task_id = $t.task_id; attempt = $attempts[$s.id] }
    Write-Host "submit $($s.id) -> $($t.task_id)"
}

while (($queue.Count -or $inFlight.Count) -and (Get-Date) -lt $deadline) {
    while ($queue.Count -and $inFlight.Count -lt $MaxInFlight) { Submit-Shot $queue.Dequeue() }
    Start-Sleep -Seconds $PollSec
    foreach ($tid in @($inFlight.Keys)) {
        $s = $inFlight[$tid]
        $st = Get-TaskStatus $tid
        if ($st.status -eq 'completed') {
            $inFlight.Remove($tid)
            # Always download (a new version is saved as <id>_vN.mp4; existing files are never reused or overwritten)
            $dl = Invoke-G @('download', '-TaskId', $tid, '-OutDir', (Join-Path $ProjectDir 'scenes'), '-BaseName', $s.id)
            $file = @($dl)[0].file
            $info = Save-QcFrames $file $s.id
            $res = if ($info -match '(\d{3,4})x(\d{3,4})') { $Matches[0] } else { '?' }
            $fps = if ($info -match '(\d+(\.\d+)?) fps') { $Matches[1] } else { '?' }
            $dur = if ($info -match 'Duration: (\d+:\d+:[\d.]+)') { $Matches[1] } else { '?' }
            $hasAudio = $info -match 'Audio:'
            $manifest[$s.id] = [pscustomobject]@{ status = 'GENERATED'; task_id = $tid; attempts = $attempts[$s.id]; file = ('scenes\' + [IO.Path]::GetFileName($file)); sha256 = @($dl)[0].sha256; resolution = $res; fps = $fps; duration = $dur; audio = $hasAudio; error = $null; model = 'meta_muse'; qc_status = 'PENDING_REVIEW' }
            Save-Manifest; Write-Log @{ event = 'done'; shot = $s.id; task_id = $tid; file = $file; res = $res; fps = $fps; dur = $dur }
            Write-Host "done  $($s.id) $res $fps fps $dur"
        }
        elseif ($st.status -in @('failed', 'stopped')) {
            $inFlight.Remove($tid)
            $policy = "$($st.error)" -match 'CONTENT_POLICY'
            Write-Log @{ event = 'fail'; shot = $s.id; task_id = $tid; error = "$($st.error)" }
            # Muse content-policy refusals are often random: one automatic resend with the same prompt
            if ($attempts[$s.id] -lt 2) { Write-Host "retry $($s.id): $($st.error)"; $queue.Enqueue($s) }
            else {
                $manifest[$s.id] = [pscustomobject]@{ status = $(if ($policy) { 'FAILED_POLICY' } else { 'FAILED' }); task_id = $tid; attempts = $attempts[$s.id]; file = $null; error = "$($st.error)"; model = 'meta_muse' }
                Save-Manifest; Write-Host "FAIL  $($s.id): $($st.error)"
            }
        }
    }
}
if ($queue.Count -or $inFlight.Count) { Write-Host "TIMEOUT: $($queue.Count) queued, $($inFlight.Count) in flight (tasks keep running in G-Labs; rerun this script to resume)" }
$sel = $targets | ForEach-Object { $manifest[$_.id] }
Write-Host ("SUMMARY: " + (($sel | Group-Object status | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '))

<#
Assembles the final master from accepted clips (job_manifest.json) in storyboard order.
 - trims each clip to its QC in/out points, removes surplus so the total is exactly target frames
 - upscales to 1920x1080 (lanczos; crop-to-fill for odd sizes), 24 fps, yuv420p, H.264
 - GPU encoding by default (-Encoder auto: NVIDIA NVENC -> Intel QSV -> AMD AMF -> CPU x264); any clip that
   fails on the GPU is re-encoded on the CPU automatically
 - audio: mono -> stereo 48 kHz, 40 ms fades at every cut, final EBU R128 loudness normalisation
 - optional -MusicFile: licensed instrumental bed mixed ~15 dB under the natural sound (looped)
Never overwrites an existing final video (writes final_video_vN.mp4).

  .\assemble.ps1 -ProjectDir <OUTPUT_ROOT\slug> [-Encoder auto|nvenc|qsv|amf|cpu] [-Grade none|soft|bright] [-MusicFile <path>]
#>
param([Parameter(Mandatory = $true)][string]$ProjectDir, [int]$Parallel = 6, [string]$MusicFile, [double]$TargetLufs = -16,
    [ValidateSet('none', 'soft', 'bright')][string]$Grade = 'none',
    [ValidateSet('auto', 'nvenc', 'qsv', 'amf', 'cpu')][string]$Encoder = 'auto')
# Grades measured on meta_muse footage (base luma ~77, sat ~11):
#   soft   -> luma ~101, sat ~16 (natural, gentle lift)
#   bright -> luma ~113, sat ~17.5 (close to the reference channel look; watch bright windows)
$gradeVf = @{ none = ''; soft = ',eq=brightness=0.04:contrast=1.04:saturation=1.45:gamma=1.22'; bright = ',eq=brightness=0.05:contrast=1.05:saturation=1.6:gamma=1.38' }[$Grade]
$ErrorActionPreference = 'Stop'
$ff = 'C:\Users\Admin\AppData\Local\Programs\G-Labs Studio\bin\ffmpeg\win\ffmpeg.exe'
# Video encoder presets (visually ~CRF 18-19)
$encArgs = @{
    cpu   = '-c:v libx264 -preset medium -crf 18'
    nvenc = '-c:v h264_nvenc -preset p5 -tune hq -rc vbr -cq 19 -b:v 0 -maxrate 20M -bufsize 40M -profile:v high'
    qsv   = '-c:v h264_qsv -preset slower -global_quality 20 -profile:v high'
    amf   = '-c:v h264_amf -quality quality -rc cqp -qp_i 18 -qp_p 20 -profile:v high'
}
function Test-Encoder([string]$name) {
    $codec = ($encArgs[$name] -split ' ')[1]
    $o = cmd /c "`"$ff`" -hide_banner -loglevel error -f lavfi -i color=c=black:s=1920x1080:r=24:d=0.5 -c:v $codec -f null - 2>&1" | Out-String
    return ($LASTEXITCODE -eq 0 -and -not $o.Trim())
}
if ($Encoder -eq 'auto') {
    $Encoder = 'cpu'
    foreach ($cand in 'nvenc', 'qsv', 'amf') { if (Test-Encoder $cand) { $Encoder = $cand; break } }
} elseif ($Encoder -ne 'cpu' -and -not (Test-Encoder $Encoder)) { Write-Warning "$Encoder not available - using CPU"; $Encoder = 'cpu' }
if ($Encoder -eq 'nvenc') { $Parallel = [Math]::Min($Parallel, 5) }   # consumer NVENC session limit
Write-Host "video encoder: $Encoder (parallel $Parallel)"
$proj = Join-Path $ProjectDir 'project'
$plan = Get-Content -Raw -Encoding UTF8 (Join-Path $proj 'canonical_payload.json') | ConvertFrom-Json
$man = Get-Content -Raw -Encoding UTF8 (Join-Path $proj 'job_manifest.json') | ConvertFrom-Json
$fps = [int]$plan.production.fps; $target = [int]$plan.production.total_frames
$edit = Join-Path $ProjectDir 'edit'; $clipDir = Join-Path $edit 'clips'
New-Item -ItemType Directory -Force $clipDir, (Join-Path $ProjectDir 'video') | Out-Null

# 1. Edit list
$list = @()
foreach ($s in ($plan.shots | Sort-Object order)) {
    $e = $man.($s.id)
    if (-not $e -or $e.status -ne 'ACCEPTED' -or -not $e.file) { continue }
    $in = [double]$e.in_s; $out = [double]$e.out_s
    $n = [int][Math]::Floor(($out - $in) * $fps)
    if ($n -le 0) { continue }
    $list += [pscustomobject]@{ order = $s.order; id = $s.id; act = ($s.purpose -split ':')[0]; file = (Join-Path $ProjectDir $e.file); in_s = $in; frames = $n }
}
$sum = ($list | Measure-Object frames -Sum).Sum
if ($sum -lt $target) { throw "Not enough footage: $sum frames < $target" }
$excess = $sum - $target
while ($excess -gt 0) {   # shave surplus one frame at a time from the tails of the longest clips
    foreach ($c in ($list | Sort-Object frames -Descending)) { if ($excess -le 0) { break }; $c.frames--; $excess-- }
}
$t = 0
foreach ($c in $list) { $c | Add-Member start_frame $t; $t += $c.frames }
[IO.File]::WriteAllText((Join-Path $edit 'edit_list.json'), ($list | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
Write-Host "clips: $($list.Count)  frames: $t (target $target)"

# 2. Render normalised clips in parallel (resumable: existing clip files are kept)
$procs = @()
$i = 0
foreach ($c in $list) {
    $i++
    # Cache key = shot id + in point + frame count, so unchanged clips are reused after re-ordering or drops
    $outClip = Join-Path $clipDir ('{0}_in{1}_f{2}_{3}_{4}.mp4' -f $c.id, ([int]($c.in_s * 1000)), $c.frames, $Grade, $Encoder)
    $c | Add-Member clip $outClip
    if (Test-Path $outClip) { continue }
    while (@($procs | Where-Object { -not $_.HasExited }).Count -ge $Parallel) { Start-Sleep -Milliseconds 300 }
    $dur = $c.frames / $fps
    $fadeOut = [Math]::Max(0, $dur - 0.04)
    $vf = 'scale=1920:1080:force_original_aspect_ratio=increase:flags=lanczos,crop=1920:1080,setsar=1,fps=' + $fps + $gradeVf + ',format=yuv420p'
    $af = 'aresample=48000,pan=stereo|c0=c0|c1=c0,afade=t=in:d=0.04,afade=t=out:st=' + $fadeOut.ToString([Globalization.CultureInfo]::InvariantCulture) + ':d=0.04,apad,atrim=0:' + $dur.ToString([Globalization.CultureInfo]::InvariantCulture)
    $ss = $c.in_s.ToString([Globalization.CultureInfo]::InvariantCulture)
    $args = "-hide_banner -loglevel error -y -ss $ss -i `"$($c.file)`" -frames:v $($c.frames) -vf `"$vf`" -af `"$af`" $($encArgs[$Encoder]) -r $fps -video_track_timescale 12288 -c:a aac -b:a 192k -ar 48000 -ac 2 `"$outClip`""
    $c | Add-Member render_args $args
    $procs += Start-Process -FilePath $ff -ArgumentList $args -NoNewWindow -PassThru -RedirectStandardError (Join-Path $edit "err_$i.log")
}
$procs | ForEach-Object { $_.WaitForExit() }
# GPU failures (e.g. encoder session limit) -> re-encode those clips on the CPU, same parameters otherwise
$retry = @($list | Where-Object { $_.render_args -and (-not (Test-Path $_.clip) -or (Get-Item $_.clip).Length -lt 10000) })
foreach ($c in $retry) {
    Write-Warning "GPU encode failed for $($c.id) - retrying on CPU"
    $cpuArgs = $c.render_args.Replace($encArgs[$Encoder], $encArgs['cpu'])
    cmd /c "`"$ff`" $cpuArgs 2>&1" | Out-Null
}
$bad = @($list | Where-Object { -not (Test-Path $_.clip) -or (Get-Item $_.clip).Length -lt 10000 })
if ($bad) { throw "Clip render failed: $($bad.id -join ', ') (see edit\err_*.log)" }
Get-ChildItem $edit -Filter 'err_*.log' | Where-Object Length -eq 0 | Remove-Item
Write-Host "rendered clips: $($list.Count)"

# 3. Concat + loudness (+ optional music bed)
$concat = Join-Path $edit 'concat.txt'
[IO.File]::WriteAllText($concat, (($list | ForEach-Object { "file '" + ($_.clip -replace '\\', '/') + "'" }) -join "`n"), (New-Object Text.UTF8Encoding($false)))
$joined = Join-Path $edit 'joined.mp4'
cmd /c "`"$ff`" -hide_banner -loglevel error -y -f concat -safe 0 -i `"$concat`" -c copy `"$joined`" 2>&1" | Out-Host
$final = Join-Path $ProjectDir 'video\final_video.mp4'; $v = 2
while (Test-Path $final) { $final = Join-Path $ProjectDir "video\final_video_v$v.mp4"; $v++ }
$inv = [Globalization.CultureInfo]::InvariantCulture
$premix = $joined
if ($MusicFile) {
    $premix = Join-Path $edit 'premix.mka'
    $fc = "[1:a]aresample=48000,volume=-15dB[mus];[0:a][mus]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[a]"
    cmd /c "`"$ff`" -hide_banner -loglevel error -y -i `"$joined`" -stream_loop -1 -i `"$MusicFile`" -filter_complex `"$fc`" -map 0:v -map [a] -c:v copy -c:a pcm_s16le `"$premix`" 2>&1" | Out-Host
}
# Two-pass EBU R128 loudness normalisation (linear) to $TargetLufs, true peak -1.5 dBTP
$I = $TargetLufs.ToString($inv)
$measure = cmd /c "`"$ff`" -hide_banner -i `"$premix`" -vn -af loudnorm=I=$($I):TP=-1.5:LRA=11:print_format=json -f null - 2>&1" | Out-String
$js = $measure.Substring($measure.LastIndexOf('{')); $js = $js.Substring(0, $js.IndexOf('}') + 1) | ConvertFrom-Json
$ln = "loudnorm=I=$($I):TP=-1.5:LRA=11:measured_I=$($js.input_i):measured_TP=$($js.input_tp):measured_LRA=$($js.input_lra):measured_thresh=$($js.input_thresh):offset=$($js.target_offset):linear=true"
cmd /c "`"$ff`" -hide_banner -loglevel error -y -i `"$premix`" -map 0:v -map 0:a -c:v copy -af `"$ln,aresample=192000,alimiter=limit=0.63:attack=5:release=50:level=false,aresample=48000`" -c:a aac -b:a 192k `"$final`" 2>&1" | Out-Host
Write-Host "loudness pass 1 measured I=$($js.input_i) LUFS, TP=$($js.input_tp) dBTP"

# 4. Verify
$info = cmd /c "`"$ff`" -hide_banner -i `"$final`" 2>&1" | Out-String
$count = cmd /c "`"$ff`" -hide_banner -i `"$final`" -map 0:v -c copy -f null - 2>&1" | Out-String
$frames = if ($count -match 'frame=\s*(\d+)') { [int]$Matches[1] } else { -1 }
Write-Host "FINAL: $final"
($info -split "`n" | Where-Object { $_ -match 'Duration|Stream' }) | Out-Host
Write-Host "video frames: $frames (target $target) -> $(if ($frames -eq $target) { 'OK' } else { 'MISMATCH' })"
Write-Host ("sha256: " + (Get-FileHash -Algorithm SHA256 $final).Hash)

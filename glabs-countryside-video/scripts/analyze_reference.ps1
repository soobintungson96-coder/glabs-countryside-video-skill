<#
Analyses a reference video supplied by the user (local file) for story structure and visual style.
Outputs to -OutDir:
  analysis.json        shot list (start, duration), pacing stats, colour stats, loudness, silence
  frames\NNNN.jpg      one labelled keyframe per shot (middle frame)
  sheet_NN.jpg         contact sheets (6 x 5 keyframes) for Claude to review
Learns structure and style only - never copy specific scenes, people, logos or content of another channel.

  .\analyze_reference.ps1 -Video <file.mp4> -OutDir <OUTPUT_ROOT\_reference_analysis\name> [-SceneThreshold 0.3]
#>
param([Parameter(Mandatory = $true)][string]$Video, [Parameter(Mandatory = $true)][string]$OutDir, [double]$SceneThreshold = 0.3)
$ErrorActionPreference = 'Stop'
$ff = 'C:\Users\Admin\AppData\Local\Programs\G-Labs Studio\bin\ffmpeg\win\ffmpeg.exe'
$inv = [Globalization.CultureInfo]::InvariantCulture
if (-not (Test-Path -LiteralPath $Video)) { throw "Video not found: $Video" }
$Video = (Resolve-Path -LiteralPath $Video).Path
New-Item -ItemType Directory -Force $OutDir, (Join-Path $OutDir 'frames') | Out-Null
function FF([string]$a) { cmd /c "`"$ff`" $a 2>&1" | Out-String }

# Basic info
$info = FF "-hide_banner -i `"$Video`""
$dur = if ($info -match 'Duration: (\d+):(\d+):([\d.]+)') { [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [double]::Parse($Matches[3], $inv) } else { throw 'Cannot read duration' }
$res = if ($info -match ', (\d{3,5})x(\d{3,5})') { "$($Matches[1])x$($Matches[2])" } else { '?' }
$fps = if ($info -match '([\d.]+) fps') { $Matches[1] } else { '?' }
Write-Host "duration $([Math]::Round($dur,1)) s, $res, $fps fps"

# 1. Scene cuts
$th = $SceneThreshold.ToString($inv)
$sc = FF "-hide_banner -i `"$Video`" -an -vf `"scale=480:-2,select='gt(scene\,$th)',showinfo`" -f null -"
$cuts = @([regex]::Matches($sc, 'pts_time:([\d.]+)') | ForEach-Object { [double]::Parse($_.Groups[1].Value, $inv) } | Where-Object { $_ -gt 0.3 })
$bounds = @(0.0) + $cuts + @($dur)
$shots = @()
for ($i = 0; $i -lt $bounds.Count - 1; $i++) {
    $d = $bounds[$i + 1] - $bounds[$i]
    if ($d -lt 0.25) { continue }
    $shots += [pscustomobject]@{ n = $shots.Count + 1; start = [Math]::Round($bounds[$i], 2); duration = [Math]::Round($d, 2) }
}
$ds = $shots.duration | Sort-Object
$stats = [ordered]@{ shots = $shots.Count; avg_s = [Math]::Round(($ds | Measure-Object -Average).Average, 2); median_s = $ds[[int]($ds.Count / 2)]; min_s = $ds[0]; max_s = $ds[-1]
    under_3s = @($ds | Where-Object { $_ -lt 3 }).Count; s3_to_6 = @($ds | Where-Object { $_ -ge 3 -and $_ -lt 6 }).Count; s6_to_10 = @($ds | Where-Object { $_ -ge 6 -and $_ -lt 10 }).Count; over_10s = @($ds | Where-Object { $_ -ge 10 }).Count }
Write-Host "shots: $($stats.shots), avg $($stats.avg_s) s, median $($stats.median_s) s"

# 2. Labelled keyframes + contact sheets
$font = "fontfile='C\:/Windows/Fonts/arial.ttf'"
foreach ($s in $shots) {
    $t = ($s.start + $s.duration / 2).ToString($inv)
    $mm = [int][Math]::Floor($s.start / 60); $ss = [int][Math]::Floor($s.start % 60)
    $label = ('#{0}  {1:D2}\:{2:D2}  {3}s' -f $s.n, $mm, $ss, $s.duration.ToString('0.0', $inv))
    $out = Join-Path $OutDir ('frames\{0:D4}.jpg' -f $s.n)
    $null = FF "-hide_banner -loglevel error -y -ss $t -i `"$Video`" -frames:v 1 -vf `"scale=400:224:force_original_aspect_ratio=decrease:force_divisible_by=2,pad=400:224:(ow-iw)/2:(oh-ih)/2,drawtext=$($font):text='$label':x=6:y=6:fontsize=18:fontcolor=yellow:box=1:boxcolor=black@0.6`" `"$out`""
}
$null = FF "-hide_banner -loglevel error -y -framerate 1 -start_number 1 -i `"$(Join-Path $OutDir 'frames\%04d.jpg')`" -vf tile=6x5:padding=4:color=black `"$(Join-Path $OutDir 'sheet_%02d.jpg')`""
$sheets = @(Get-ChildItem $OutDir -Filter 'sheet_*.jpg' | ForEach-Object { $_.Name })

# 3. Colour statistics (1 frame per 2 s)
$cs = FF "-hide_banner -i `"$Video`" -an -vf `"fps=0.5,scale=320:-2,signalstats,metadata=print`" -f null -"
$y = @([regex]::Matches($cs, 'signalstats\.YAVG=([\d.]+)') | ForEach-Object { [double]::Parse($_.Groups[1].Value, $inv) })
$sat = @([regex]::Matches($cs, 'signalstats\.SATAVG=([\d.]+)') | ForEach-Object { [double]::Parse($_.Groups[1].Value, $inv) })
$hue = @([regex]::Matches($cs, 'signalstats\.HUEAVG=([\d.]+)') | ForEach-Object { [double]::Parse($_.Groups[1].Value, $inv) })
$colour = [ordered]@{ brightness_avg_0_255 = [Math]::Round(($y | Measure-Object -Average).Average, 1); saturation_avg = [Math]::Round(($sat | Measure-Object -Average).Average, 1); hue_avg_deg = [Math]::Round(($hue | Measure-Object -Average).Average, 1); samples = $y.Count }

# 4. Audio
$audio = [ordered]@{ has_audio = [bool]($info -match 'Audio:') }
if ($audio.has_audio) {
    $lu = FF "-hide_banner -i `"$Video`" -vn -af ebur128=framelog=quiet -f null -"
    if ($lu -match 'I:\s+(-?[\d.]+) LUFS') { $audio.integrated_lufs = [double]::Parse($Matches[1], $inv) }
    if ($lu -match 'LRA:\s+([\d.]+) LU') { $audio.lra_lu = [double]::Parse($Matches[1], $inv) }
    $si = FF "-hide_banner -i `"$Video`" -vn -af silencedetect=noise=-50dB:d=1 -f null -"
    $sd = @([regex]::Matches($si, 'silence_duration: ([\d.]+)') | ForEach-Object { [double]::Parse($_.Groups[1].Value, $inv) })
    $audio.silent_seconds = [Math]::Round(($sd | Measure-Object -Sum).Sum, 1); $audio.silence_ratio = [Math]::Round($audio.silent_seconds / $dur, 3)
}

$result = [ordered]@{ video = $Video; duration_s = [Math]::Round($dur, 2); resolution = $res; fps = $fps; scene_threshold = $SceneThreshold; pacing = $stats; colour = $colour; audio = $audio; contact_sheets = $sheets; shots = $shots }
[IO.File]::WriteAllText((Join-Path $OutDir 'analysis.json'), ($result | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
Write-Host "colour: brightness $($colour.brightness_avg_0_255), saturation $($colour.saturation_avg)"
if ($audio.has_audio) { Write-Host "audio: $($audio.integrated_lufs) LUFS, silence $([Math]::Round(100*$audio.silence_ratio,1))%" }
Write-Host "sheets: $($sheets -join ', ')"
Write-Host "analysis: $(Join-Path $OutDir 'analysis.json')"

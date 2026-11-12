<#
Builds labelled QC contact sheets (start / mid / end per shot) from logs\qc\<id>_{start,mid,end}.jpg.
  .\make_sheet.ps1 -ProjectDir <...> -Ids scene_021,scene_023 -Name A2   -> logs\qc\sheet_A2_1.jpg, _2.jpg ...
#>
param([Parameter(Mandatory = $true)][string]$ProjectDir, [Parameter(Mandatory = $true)][string[]]$Ids, [string]$Name = 'qc', [int]$PerSheet = 7)
$ff = 'C:\Users\Admin\AppData\Local\Programs\G-Labs Studio\bin\ffmpeg\win\ffmpeg.exe'
$Ids = @($Ids | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$qc = Join-Path $ProjectDir 'logs\qc'
$font = "fontfile='C\:/Windows/Fonts/arial.ttf'"
$n = 0
for ($o = 0; $o -lt $Ids.Count; $o += $PerSheet) {
    $grp = @($Ids[$o..([Math]::Min($o + $PerSheet, $Ids.Count) - 1)] | Where-Object { Test-Path (Join-Path $qc "$($_)_mid.jpg") })
    if (-not $grp) { continue }
    $n++; $in = ''; $filters = @(); $rows = @(); $labels = @(); $k = 0
    foreach ($id in $grp) {
        $label = $id -replace 'scene_', ''
        foreach ($pos in 'start', 'mid', 'end') {
            $in += " -i `"$(Join-Path $qc "$($id)_$pos.jpg")`""
            $filters += "[$k]scale=400:225,drawtext=$($font):text='$label $pos':x=6:y=6:fontsize=20:fontcolor=yellow:box=1:boxcolor=black@0.6[v$k]"; $k++
        }
        $b = $k - 3; $rows += "[v$b][v$($b+1)][v$($b+2)]hstack=3[r$k]"; $labels += "[r$k]"
    }
    $outs = $labels -join ''
    $fc = ($filters + $rows + $(if ($grp.Count -gt 1) { "$($outs)vstack=$($grp.Count)[out]" } else { "$($outs)null[out]" })) -join ';'
    $fcFile = Join-Path $env:TEMP "fc_sheet_$Name_$n.txt"
    [IO.File]::WriteAllText($fcFile, $fc)
    $out = Join-Path $qc "sheet_$($Name)_$n.jpg"
    cmd /c "`"$ff`" -hide_banner -loglevel error -y $in -filter_complex_script `"$fcFile`" -map [out] -frames:v 1 `"$out`" 2>&1" | Out-Null
    $out
}

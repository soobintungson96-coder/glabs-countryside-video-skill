<#
Packages a finished episode into its own folder named after the English title:

  <DeliveryRoot>\<Title>\
     <Title>.mp4               newest video\final_video*.mp4 (NTFS hard link when possible, else copy)
     thumbnail.jpg             1280x720, checked <= 2 MB
     SEO.txt                   copy of seo\SEO.txt
     description.txt           ready to paste: description + chapters + hashtags
     tags.txt                  comma-separated tags
     youtube_metadata.json     YouTube Data API v3 shaped (snippet/status) + chapters, file specs, checks

Default DeliveryRoot = <workspace>\YouTube (workspace = parent of OUTPUT_ROOT).
An existing delivery folder is never overwritten; use -Update to add changed files as name_vN.

  .\export_delivery.ps1 -ProjectDir <OUTPUT_ROOT\slug> [-DeliveryRoot <dir>] [-CategoryId 22] [-Privacy private] [-Update]
#>
param([Parameter(Mandatory = $true)][string]$ProjectDir, [string]$DeliveryRoot, [string]$CategoryId = '22',
    [ValidateSet('private', 'unlisted', 'public')][string]$Privacy = 'private', [switch]$Update)
$ErrorActionPreference = 'Stop'
$ff = 'C:\Users\Admin\AppData\Local\Programs\G-Labs Studio\bin\ffmpeg\win\ffmpeg.exe'
$ProjectDir = (Resolve-Path $ProjectDir).Path
if (-not $DeliveryRoot) { $DeliveryRoot = Join-Path (Split-Path (Split-Path $ProjectDir -Parent) -Parent) 'YouTube' }
$bible = Get-Content -Raw -Encoding UTF8 (Join-Path $ProjectDir 'project\bible.json') | ConvertFrom-Json
$seo = $bible.seo
$title = $seo.title_en.Trim()

# Inputs
$video = Get-ChildItem (Join-Path $ProjectDir 'video') -Filter 'final_video*.mp4' | Sort-Object LastWriteTime | Select-Object -Last 1
if (-not $video) { throw 'No final video found in video\' }
$thumb = Join-Path $ProjectDir 'thumbnail\thumbnail.jpg'
$seoFile = Join-Path $ProjectDir 'seo\SEO.txt'
foreach ($f in $thumb, $seoFile) { if (-not (Test-Path $f)) { throw "Missing $f" } }
$seoLines = Get-Content -Encoding UTF8 $seoFile
# [string] cast drops the PSPath/PSProvider note properties Get-Content attaches (they bloat ConvertTo-Json)
$chapters = @($seoLines | Where-Object { $_ -match '^\d{1,2}:\d\d(:\d\d)? ' } | ForEach-Object { [string]$_ })
$tagsClean = @($bible.seo.tags_en | ForEach-Object { [string]$_ })
$hashClean = @($bible.seo.hashtags_en | ForEach-Object { [string]$_ })

# Folder named after the title (Windows-safe)
$folderName = ($title -replace '[<>:"/\\|?*]', '' -replace '\s+', ' ').Trim().TrimEnd('.')
$dest = Join-Path $DeliveryRoot $folderName
if ((Test-Path $dest) -and -not $Update) { throw "Delivery folder already exists: $dest (use -Update to add new versions)" }
New-Item -ItemType Directory -Force $dest | Out-Null
function Get-FreePath([string]$path) {
    if (-not (Test-Path $path)) { return $path }
    $d = Split-Path $path; $n = [IO.Path]::GetFileNameWithoutExtension($path); $e = [IO.Path]::GetExtension($path); $v = 2
    while (Test-Path (Join-Path $d "$n`_v$v$e")) { $v++ }
    Join-Path $d "$n`_v$v$e"
}
function Put-File([string]$src, [string]$name, [switch]$Link) {
    $target = Join-Path $dest $name
    if ((Test-Path $target) -and ((Get-FileHash $target).Hash -eq (Get-FileHash $src).Hash)) { return $target }
    $target = Get-FreePath $target
    if ($Link) { try { New-Item -ItemType HardLink -Path $target -Target $src | Out-Null; return $target } catch { } }
    Copy-Item -LiteralPath $src $target
    $target
}
function Put-Text([string]$name, [string]$text) {
    $target = Join-Path $dest $name
    if ((Test-Path $target) -and ((Get-Content -Raw -Encoding UTF8 $target) -eq $text)) { return $target }
    $target = Get-FreePath $target
    [IO.File]::WriteAllText($target, $text, (New-Object Text.UTF8Encoding($false)))
    $target
}

# Video specs
$info = cmd /c "`"$ff`" -hide_banner -i `"$($video.FullName)`" 2>&1" | Out-String
$dur = if ($info -match 'Duration: (\d+:\d+:[\d.]+)') { $Matches[1] } else { '?' }
$res = if ($info -match ', (\d{3,5}x\d{3,5})') { $Matches[1] } else { '?' }
$vfps = if ($info -match '([\d.]+) fps') { $Matches[1] } else { '?' }
$tinfo = cmd /c "`"$ff`" -hide_banner -i `"$thumb`" 2>&1" | Out-String
$tres = if ($tinfo -match ', (\d{3,5}x\d{3,5})') { $Matches[1] } else { '?' }

# Description = SEO description + chapters + hashtags
$desc = $seo.description_en.Trim()
if ($chapters) { $desc += "`n`nChapters:`n" + ($chapters -join "`n") }
$desc += "`n`n" + ($hashClean -join ' ')
$tags = $tagsClean

# YouTube limits
$checks = [ordered]@{
    title_length = "$($title.Length)/100"; title_ok = ($title.Length -le 100 -and $title -notmatch '[<>]')
    description_bytes = "$([Text.Encoding]::UTF8.GetByteCount($desc))/5000"; description_ok = ([Text.Encoding]::UTF8.GetByteCount($desc) -le 5000 -and $desc -notmatch '[<>]')
    tags_chars = "$((($tags | ForEach-Object { if ($_ -match ' ') { $_.Length + 2 } else { $_.Length } }) | Measure-Object -Sum).Sum + [Math]::Max(0, $tags.Count - 1))/500"
    chapters_ok = ($chapters.Count -ge 3 -and $chapters[0] -match '^0?0:00 ')
    thumbnail_ok = ($tres -eq '1280x720' -and (Get-Item $thumb).Length -le 2MB)
    video_1080p = ($res -eq '1920x1080')
}
$checks.tags_ok = ([int]($checks.tags_chars -split '/')[0] -le 500)

# Write package
$vOut = Put-File $video.FullName "$folderName.mp4" -Link
$tOut = Put-File $thumb 'thumbnail.jpg'
$sOut = Put-File $seoFile 'SEO.txt'
$dOut = Put-Text 'description.txt' $desc
$gOut = Put-Text 'tags.txt' ($tags -join ', ')
$meta = [ordered]@{
    snippet = [ordered]@{ title = $title; description = $desc; tags = $tags; categoryId = $CategoryId; defaultLanguage = 'en'; defaultAudioLanguage = 'zxx' }
    status = [ordered]@{ privacyStatus = $Privacy; selfDeclaredMadeForKids = $false; containsSyntheticMedia = $true; license = 'youtube'; embeddable = $true; publicStatsViewable = $true }
    chapters = $chapters
    alternative_title = [string]$seo.alternative_title_en
    files = [ordered]@{ video = (Split-Path $vOut -Leaf); thumbnail = (Split-Path $tOut -Leaf); seo = (Split-Path $sOut -Leaf); description = (Split-Path $dOut -Leaf); tags = (Split-Path $gOut -Leaf) }
    video_specs = [ordered]@{ duration = $dur; resolution = $res; fps = $vfps; size_mb = [Math]::Round($video.Length / 1MB); sha256 = (Get-FileHash -Algorithm SHA256 $video.FullName).Hash; source = $video.FullName }
    thumbnail_specs = [ordered]@{ resolution = $tres; size_kb = [Math]::Round((Get-Item $thumb).Length / 1KB) }
    production = [ordered]@{ project_dir = $ProjectDir; model = $bible.model_id; preset = $bible.preset; no_dialogue = $true; ai_generated_visuals = $true; exported = (Get-Date).ToString('s') }
    upload_notes = @('containsSyntheticMedia = true: realistic AI-generated footage must be disclosed in YouTube Studio (Altered or synthetic content = Yes).', 'defaultAudioLanguage zxx = no linguistic content (no speech).', 'Upload as private first, check the video, then publish.')
    checks = $checks
}
$mOut = Put-Text 'youtube_metadata.json' ($meta | ConvertTo-Json -Depth 6)
Write-Host "DELIVERY: $dest"
Get-ChildItem $dest | ForEach-Object { "  {0}  {1:N0} KB" -f $_.Name, ($_.Length / 1KB) } | Out-Host
Write-Host ("checks: " + (($checks.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' | '))

<#
Builds the canonical plan (schema 3.4) from a project bible.json + shotlist.txt.
Frame totals are made exact; per-shot frames are clamped to [min_frames_per_shot, max_frames_per_shot].

  .\build_storyboard.ps1 -ProjectDir <OUTPUT_ROOT\slug>
Writes project\canonical_payload.json and project\storyboard.md, prints validation.
#>
param([Parameter(Mandatory = $true)][string]$ProjectDir)
$ErrorActionPreference = 'Stop'
$proj = Join-Path $ProjectDir 'project'
$bible = Get-Content -Raw -Encoding UTF8 (Join-Path $proj 'bible.json') | ConvertFrom-Json
$lines = Get-Content -Encoding UTF8 (Join-Path $proj 'shotlist.txt') | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') }

function Expand-Locks([string]$t) {
    foreach ($p in $bible.subjects.PSObject.Properties) { $t = $t.Replace('{' + $p.Name + '}', $p.Value.lock) }
    if ($bible.main_setting) { $t = $t.Replace('{MAIN}', $bible.main_setting) }
    foreach ($pr in @($bible.props)) { if ($pr) { $t = $t.Replace('{' + $pr.id + '}', $pr.lock) } }
    $t
}

$rows = @()
foreach ($l in $lines) {
    $f = $l.Split('|')
    if ($f.Count -notin 8, 9) { throw "Bad shotlist row (need 8 fields, or 9 with a fixed ID): $l" }
    # Optional 9th field = fixed shot ID, so inserted shots never renumber existing scene_NNN IDs
    $rows += [pscustomobject]@{ fixedId = $(if ($f.Count -eq 9) { $f[8].Trim() } else { $null }); type = $f[0].Trim(); sec = [double]$f[1]; act = $f[2].Trim(); size = $f[3].Trim(); cam = $f[4].Trim(); subj = @($f[5].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }); action = $f[6].Trim(); sound = $f[7].Trim() }
}

$fps = [int]$bible.fps; $target = [int][Math]::Round($bible.target_duration_seconds * $fps)
$max = [int]$bible.max_frames_per_shot; $min = [int]$bible.min_frames_per_shot
if ($rows.Count * $max -lt $target) { throw "Not enough shots: $($rows.Count) x $max = $($rows.Count*$max) < $target frames. Add at least $([Math]::Ceiling(($target - $rows.Count*$max)/$max)) shots." }
$raw = $rows | ForEach-Object { $_.sec * $fps }
$factor = $target / ($raw | Measure-Object -Sum).Sum
$frames = @($raw | ForEach-Object { [int][Math]::Max($min, [Math]::Min($max, [Math]::Floor($_ * $factor))) })
$diff = $target - ($frames | Measure-Object -Sum).Sum
$guard = 0
while ($diff -ne 0 -and $guard -lt 100000) {
    for ($i = 0; $i -lt $frames.Count -and $diff -ne 0; $i++) {
        if ($diff -gt 0 -and $frames[$i] -lt $max) { $frames[$i]++; $diff-- }
        elseif ($diff -lt 0 -and $frames[$i] -gt $min) { $frames[$i]--; $diff++ }
    }
    $guard++
}
if ($diff -ne 0) { throw "Could not distribute frames exactly (residual $diff)" }

$sizeMap = @{ 'extreme wide' = 'WIDE'; 'wide' = 'WIDE'; 'medium' = 'MEDIUM'; 'close' = 'CLOSE'; 'macro' = 'MACRO' }
$human = @('G', 'N', 'O'); $locCodes = @('HI', 'HX', 'HB', 'CL', 'P'); $indoor = @('HI', 'HB', 'CL')
# §15.4 default look: vivid, flattering, true-to-life (overridable with bible.look)
$look = if ($bible.look) { $bible.look } else { 'Vivid yet natural, flattering colours: warm directional sunlight, fresh green grass, clear sky, rich but true-to-life tones. Real skin texture with pores, visible fabric weave and wood grain, subtle film grain, natural imperfections; looks like a real camera, not AI.' }
$antiAi = 'plastic skin, waxy skin, airbrushed, porcelain skin, over-sharpened, HDR halo, neon sky, CGI, 3D render, video game look, oversaturated'
$anachronism = 'plastic objects, garden hose, modern clothing, brand labels, embossed lettering, printed text on objects'
$warnings = @()
$shots = @()
$autoN = 0
for ($i = 0; $i -lt $rows.Count; $i++) {
    $r = $rows[$i]
    if ($r.fixedId) { $shotId = $r.fixedId } else { $autoN++; $shotId = ('scene_{0:D3}' -f $autoN) }
    # Subject tokens may carry a wardrobe variant: "G:night"
    $variant = @{}
    $codes = @($r.subj | ForEach-Object { $c, $v = $_.Split(':'); if ($v) { $variant[$c] = $v }; $c })
    $chars = @($codes | Where-Object { $_ -notin $locCodes })
    $locs = @($codes | Where-Object { $_ -in $locCodes })
    $refIds = @()
    foreach ($c in ($chars | Where-Object { $_ -ne 'C' })) {
        # A variant outfit differs from the full-body ref, so use the face portrait when one exists
        if ($variant[$c] -and ($bible.reference_images | Where-Object id -eq ($bible.subjects.$c.id + '_portrait'))) { $refIds += $bible.subjects.$c.id + '_portrait' }
        else { $refIds += $bible.subjects.$c.id }
    }
    if ($locs) { $refIds += $bible.subjects.($locs[0]).id }
    elseif (($r.type -eq 'BROLL' -or $chars -contains 'C') -and $bible.subjects.P) { $refIds += $bible.subjects.P.id }
    # Wide exterior shots lock geography to the master setting
    if ($bible.main_setting -and $r.size -match 'wide' -and ($locs -contains 'HX' -or $locs -contains 'P')) { $refIds += 'loc_master' }
    $propLocks = @()
    foreach ($pr in @($bible.props)) {
        if ($pr -and $r.action -match $pr.match) { $refIds += $pr.id; $propLocks += $pr.lock }
    }
    $refIds = @($refIds | Select-Object -Unique | Select-Object -First 3)   # meta_muse video: max 3 refs
    # meta_muse treats a single ref as the literal first frame; keep 2+ refs by borrowing the last location for continuity
    if ($locs) { $lastLoc = $bible.subjects.($locs[0]).id }
    if ($refIds.Count -lt 2 -and $lastLoc -and $refIds -notcontains $lastLoc) { $refIds += $lastLoc }
    if ($refIds.Count -lt 2) {
        $pair = @{ loc_pasture = 'loc_master'; loc_hut_exterior = 'loc_master'; loc_master = 'loc_pasture'; loc_hut_interior = 'prop_copper_cauldron'; loc_cellar = 'loc_hut_interior'; loc_sleeping_nook = 'loc_hut_interior' }
        if ($refIds.Count -eq 1 -and $pair[$refIds[0]]) { $refIds += $pair[$refIds[0]] }
        # Generic fallback for any project: pair with the master setting, or with the first location reference
        $refList = @($bible.reference_images | ForEach-Object { $_.id })
        if ($refIds.Count -eq 1) {
            $fb = if ($refIds[0] -ne 'loc_master' -and $refList -contains 'loc_master') { 'loc_master' } else { @($refList | Where-Object { $_ -like 'loc_*' -and $_ -ne $refIds[0] })[0] }
            if ($fb) { $refIds += $fb }
        }
    }

    $who = (@($chars | ForEach-Object { if ($variant[$_]) { $bible.subjects.$_.variants.($variant[$_]) } else { $bible.subjects.$_.lock } }) -join '; ')
    $whereParts = @($locs | ForEach-Object { $bible.subjects.$_.lock })
    if ($bible.main_setting -and ($locs -contains 'HX' -or ($locs -contains 'P' -and $r.size -match 'wide'))) { $whereParts += "Main setting layout: $($bible.main_setting)" }
    if ($propLocks) { $whereParts += "Props: $($propLocks -join '; ')" }
    $where = ($whereParts -join '; ')
    $img = @()
    if ($who) { $img += "Characters: $who." }
    $img += "Scene: $($r.action)."
    if ($where) { $img += "Setting: $where." }
    $img += "$($r.size) shot. " + $bible.style + ' ' + $look
    $vid = "$($r.action). Camera: $($r.cam). "
    if ($bible.camera_lock -and $r.cam -match 'static') { $vid += $bible.camera_lock + ' ' }
    $vid += $bible.motion_rule + ' ' + $bible.no_speech
    $hasHuman = [bool]($chars | Where-Object { $_ -in $human })
    $nHuman = @($chars | Where-Object { $_ -in $human }).Count
    # §15 rule checks (warnings, not errors)
    if ($r.cam -match '(?i)fast|quick|whip|handheld|shaky|zoom|orbit|spin|crane|drone|fpv') { $warnings += "$shotId camera '$($r.cam)' is not slow/static (rule 15.3)" }
    if ($nHuman -ge 2 -and $r.action -match '(?i)\btogether\b|\bthey\b|\bboth\b|the three|side by side|\ball\b') { $warnings += "$shotId several characters doing the same action - give each a distinct task (rule 15.1): $($r.action)" }
    if (-not $r.sound) { $warnings += "$shotId missing action sound (rule 15.2)" }
    $risks = @()
    $neg = @($bible.negative_base, $antiAi, $anachronism)
    if ($hasHuman) { $risks += 'character identity consistency' }
    if ($hasHuman -and $r.size -match 'close|macro') { $risks += 'hand anatomy and grip'; $neg += 'six fingers, deformed hands' }
    if ($r.action -match 'milk|whey|water|pour|brine|tea|cream') { $risks += 'liquid physics'; $neg += 'liquid flowing upward, liquid passing through containers' }
    if ($r.action -match 'fire|flame|match|lamp') { $risks += 'fire behaviour' }
    if ($r.action -match 'curd|cheese|butter') { $risks += 'food state continuity' }
    if ($chars -contains 'D' -or $chars -contains 'C' -or $r.action -match 'bird|marmot|chamois|eagle|bee|butterfly|pig|grasshopper|chough') { $risks += 'realistic animal behaviour'; $neg += 'extra legs, deformed animals, human-like animal faces' }
    if (-not $risks) { $risks += 'landscape temporal consistency' }
    $prevA = if ($i -gt 0) { $rows[$i - 1].action } else { 'Episode opens' }
    $nextA = if ($i -lt $rows.Count - 1) { $rows[$i + 1].action } else { 'Episode ends' }
    $shots += [ordered]@{
        id = $shotId; order = $i + 1; scene_type = $r.type; duration_frames = $frames[$i]
        purpose = "$($r.act): $($r.action)"
        continuity_before = "Follows: $prevA"; continuity_after = "Leads into: $nextA"
        subjects = @($chars | ForEach-Object { $bible.subjects.$_.id }); reference_ids = $refIds
        shot_size = $sizeMap[$r.size.ToLower()]; camera_motion = $r.cam
        image_prompt = ($img -join ' '); video_prompt = $vid
        negative_prompt = ($neg -join ', ')
        audio_prompt = "$($r.sound). $(if ($locs | Where-Object { $_ -in $indoor }) { 'Indoor ambience: quiet wooden room tone, soft fire crackle, outside sounds only faint and muffled.' } elseif ($locs) { 'Open-air ambience: light mountain wind, distant birds, faraway cowbells.' } else { 'Ambience consistent with the previous shot location.' }) Only sounds of objects visible or present in this place. Natural ambient ASMR only. No speech, no human voices, no sung vocals."
        qc_risks = $risks
    }
}

$characters = @()
foreach ($ref in $bible.reference_images) {
    $code = ($bible.subjects.PSObject.Properties | Where-Object { $ref.id.StartsWith($_.Value.id) } | Select-Object -First 1)
    $prop = @($bible.props) | Where-Object { $_ -and $_.id -eq $ref.id } | Select-Object -First 1
    $role = if ($ref.role) { $ref.role } elseif ($prop) { 'prop' } elseif ($code) { $code.Value.role } else { 'reference' }
    $lock = if ($ref.id -eq 'loc_master') { $bible.main_setting } elseif ($prop) { $prop.lock } elseif ($code) { $code.Value.lock } else { $ref.prompt }
    $refPrompt = (Expand-Locks $ref.prompt) + ' ' + $bible.style
    if ($ref.derive_from) { $refPrompt = "[Generate image_to_image from reference '$($ref.derive_from)'] " + $refPrompt }
    $characters += [ordered]@{ id = $ref.id; role = $role; appearance_lock = $lock; reference_image_prompt = $refPrompt; asset_uri = $null }
}

$out = $ProjectDir
$plan = [ordered]@{
    schema_version = '3.4'; original_title = $bible.original_title
    preflight_configuration = [ordered]@{ target_duration_seconds = $bible.target_duration_seconds; character_choice = $bible.character_choice; location = $bible.location; model_id = $bible.model_id; quality_choice = $bible.quality_choice; output_folder = $out }
    production = [ordered]@{ fps = $fps; total_frames = $target; resolution = $(if ($bible.quality_choice -eq '4K_UHD') { '3840x2160' } else { '1920x1080' }); aspect_ratio = '16:9'; cut_style = 'hard_cut'; watermark_enabled = $false; subtitles_enabled = $false }
    characters = $characters; shots = $shots
    audio_policy = [ordered]@{ dialogue_enabled = $false; voiceover_enabled = $false; singing_lyrics_enabled = $false; speech_in_background_enabled = $false; ambient_asmr_enabled = $true; instrumental_music_only = $true; music_license_required = $true }
    thumbnail = [ordered]@{ image_prompt = (Expand-Locks $bible.thumbnail.image_prompt); width = $bible.thumbnail.width; height = $bible.thumbnail.height; text_overlay_enabled = $bible.thumbnail.text_overlay_enabled }
    seo = $bible.seo
    deliverables = [ordered]@{ video = 'video/final_video.mp4'; thumbnail = 'thumbnail/thumbnail.jpg'; seo = 'seo/SEO.txt'; storyboard = 'project/storyboard.json'; job_manifest = 'project/job_manifest.json' }
    approvals = [ordered]@{ configuration_approved = $true; storyboard_approved = $false; execution_approved = $false }
    provider = [ordered]@{ provider = 'glabs_studio'; adapter_status = 'READY'; render_kind = 'UNCONFIRMED' }
}
$json = $plan | ConvertTo-Json -Depth 20
[IO.File]::WriteAllText((Join-Path $proj 'canonical_payload.json'), $json, (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $proj 'storyboard.json'), ($shots | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))

# Human-readable storyboard
$md = @("# Storyboard - $($bible.original_title)", '', "Total: $target frames @ ${fps}fps = $($target/$fps) s | shots: $($shots.Count)", '', '| # | Type | Act | Time | Frames | Size | Subjects | Action |', '|---|---|---|---|---|---|---|---|')
$t = 0
foreach ($s in $shots) {
    $ts = [TimeSpan]::FromSeconds($t / $fps); $t += $s.duration_frames
    $md += "| $($s.order) | $($s.scene_type) | $($rows[$s.order-1].act) | $($ts.ToString('mm\:ss')) | $($s.duration_frames) | $($s.shot_size) | $(($rows[$s.order-1].subj) -join ',') | $($rows[$s.order-1].action) |"
}
[IO.File]::WriteAllText((Join-Path $proj 'storyboard.md'), ($md -join "`n"), (New-Object Text.UTF8Encoding($false)))

# Validation (port of validate_plan.py core checks)
$sum = ($shots | ForEach-Object { $_.duration_frames } | Measure-Object -Sum).Sum
$broll = ($shots | Where-Object { $_.scene_type -eq 'BROLL' } | ForEach-Object { $_.duration_frames } | Measure-Object -Sum).Sum
$ids = $shots | ForEach-Object { $_.id }
$errors = @()
if ($sum -ne $target) { $errors += "frame sum $sum != $target" }
if (($ids | Select-Object -Unique).Count -ne $ids.Count) { $errors += 'duplicate ids' }
if ($shots | Where-Object { $_.duration_frames -gt $max -or $_.duration_frames -lt $min }) { $errors += 'shot frames out of range' }
if ($bible.seo.title_en.Length -gt 100) { $errors += 'SEO title > 100 chars' }
$dupActions = $rows | Group-Object action | Where-Object Count -gt 1
if ($dupActions) { $errors += "duplicate actions: $(($dupActions | ForEach-Object Name) -join '; ')" }
"shots=$($shots.Count) MAIN=$(@($shots | Where-Object scene_type -eq 'MAIN').Count) BROLL=$(@($shots | Where-Object scene_type -eq 'BROLL').Count)"
"frames=$sum target=$target  min/max per shot=$(($shots.duration_frames | Measure-Object -Minimum -Maximum) | ForEach-Object { "$($_.Minimum)/$($_.Maximum)" })"
$bt = if ($bible.broll_target) { @([double]$bible.broll_target[0], [double]$bible.broll_target[1]) } else { @(0.20, 0.30) }
$br = $broll / $sum
"broll_ratio=" + [Math]::Round(100 * $br, 1) + "% (target $([int](100*$bt[0]))-$([int](100*$bt[1]))%$(if ($bible.preset) { ', preset ' + $bible.preset }))"
if ($br -lt $bt[0] - 0.005 -or $br -gt $bt[1] + 0.005) { $warnings += "B-roll ratio $([Math]::Round(100*$br,1))% outside target range" }
"approx runtime per act:"; $rows | ForEach-Object -Begin { $k = 0 } -Process { [pscustomobject]@{ act = $_.act; f = $frames[$k] }; $k++ } | Group-Object act | ForEach-Object { "  $($_.Name): $([TimeSpan]::FromSeconds((($_.Group | Measure-Object f -Sum).Sum)/$fps).ToString('mm\:ss')) ($($_.Count) shots)" }
$camMoving = @($rows | Where-Object { $_.cam -notmatch 'static' }).Count
if ($camMoving -gt [Math]::Ceiling($rows.Count / 3)) { $warnings += "$camMoving of $($rows.Count) shots have camera movement (> 1/3, rule 15.3)" }
$warnings | ForEach-Object { "WARNING: $_" }
if ($errors) { $errors | ForEach-Object { "ERROR: $_" }; 'RESULT: FAIL' } else { 'RESULT: PASS (draft - storyboard not yet approved)' }

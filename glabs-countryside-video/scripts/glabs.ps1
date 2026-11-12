<#
G-Labs Studio local webhook adapter (Windows PowerShell 5.1, no Python needed).

Reads GLABS_BASE_URL / GLABS_API_KEY from .env.glabs (project root) or environment.
The API key is sent only as the X-API-Key header and is never printed.

Usage examples:
  .\glabs.ps1 health
  .\glabs.ps1 tasks
  .\glabs.ps1 characters
  .\glabs.ps1 submit -Endpoint video -BodyFile shot_001.json      # PAID: only after plan approval
  .\glabs.ps1 status   -TaskId <id>
  .\glabs.ps1 wait     -TaskId <id> [-TimeoutSec 1800]
  .\glabs.ps1 result   -TaskId <id>
  .\glabs.ps1 download -TaskId <id> -OutDir <folder> [-BaseName scene_001]
  .\glabs.ps1 stop     -TaskId <id>

Body files: JSON exactly as the G-Labs endpoint expects. Convenience: any entry of
"reference_images" written as "file:C:\path\img.png" (or {"file": "...", "name": "luna"})
is converted to a base64 data URI before sending.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('health', 'tasks', 'characters', 'submit', 'status', 'result', 'wait', 'download', 'stop')]
    [string]$Action,
    [ValidateSet('video', 'image', 'grok', 'meta', 'openai', 'upscale')]
    [string]$Endpoint,
    [string]$BodyFile,
    [string]$TaskId,
    [string]$OutDir,
    [string]$BaseName,
    [int]$TimeoutSec = 1800,
    [string]$EnvFile
)

$ErrorActionPreference = 'Stop'

function Import-GlabsEnv {
    $candidates = @()
    if ($EnvFile) { $candidates += $EnvFile }
    $candidates += (Join-Path (Get-Location) '.env.glabs')
    $candidates += (Join-Path $PSScriptRoot '..\..\..\..\.env.glabs')
    foreach ($f in $candidates) {
        if (Test-Path $f) {
            foreach ($line in Get-Content -Encoding UTF8 $f) {
                if ($line -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)\s*$') {
                    if (-not [Environment]::GetEnvironmentVariable($Matches[1])) {
                        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2])
                    }
                }
            }
            break
        }
    }
    if (-not $env:GLABS_BASE_URL) { $env:GLABS_BASE_URL = 'http://127.0.0.1:8765' }
}

function Get-Headers { if (-not $env:GLABS_API_KEY) { throw 'GLABS_API_KEY not set (.env.glabs missing?)' }; @{ 'X-API-Key' = $env:GLABS_API_KEY } }

function Invoke-Glabs([string]$Method, [string]$Path, $Body = $null, [switch]$NoAuth) {
    $uri = $env:GLABS_BASE_URL.TrimEnd('/') + $Path
    $params = @{ Method = $Method; Uri = $uri; UseBasicParsing = $true; TimeoutSec = 120 }
    if (-not $NoAuth) { $params.Headers = Get-Headers }
    if ($null -ne $Body) {
        $params.ContentType = 'application/json; charset=utf-8'
        $params.Body = [Text.Encoding]::UTF8.GetBytes($Body)
    }
    try {
        $r = Invoke-WebRequest @params
        $text = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        return ($text | ConvertFrom-Json)
    } catch {
        $resp = $_.Exception.Response
        if ($resp) {
            $msg = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
            throw "HTTP $([int]$resp.StatusCode) on $Method $Path : $msg"
        }
        throw
    }
}

function ConvertTo-DataUri([string]$path) {
    $full = (Resolve-Path $path).Path
    $ext = [IO.Path]::GetExtension($full).ToLower()
    $mime = switch ($ext) { '.png' { 'image/png' } '.jpg' { 'image/jpeg' } '.jpeg' { 'image/jpeg' } '.webp' { 'image/webp' } '.mp4' { 'video/mp4' } default { 'application/octet-stream' } }
    "data:$mime;base64," + [Convert]::ToBase64String([IO.File]::ReadAllBytes($full))
}

function Expand-Body([string]$file) {
    $obj = Get-Content -Raw -Encoding UTF8 $file | ConvertFrom-Json
    if ($obj.PSObject.Properties.Name -contains 'reference_images') {
        $out = @()
        foreach ($ref in @($obj.reference_images)) {
            if ($ref -is [string] -and $ref.StartsWith('file:')) { $out += (ConvertTo-DataUri $ref.Substring(5)) }
            elseif ($ref -isnot [string] -and $ref.PSObject.Properties.Name -contains 'file') {
                $o = [ordered]@{ data = (ConvertTo-DataUri $ref.file) }
                if ($ref.name) { $o.name = $ref.name }
                $out += [pscustomobject]$o
            } else { $out += $ref }
        }
        $obj.reference_images = $out
    }
    $obj | ConvertTo-Json -Depth 20 -Compress
}

function Get-UniquePath([string]$dir, [string]$name) {
    $p = Join-Path $dir $name
    if (-not (Test-Path $p)) { return $p }
    $stem = [IO.Path]::GetFileNameWithoutExtension($name); $ext = [IO.Path]::GetExtension($name); $i = 2
    while (Test-Path (Join-Path $dir "$stem`_v$i$ext")) { $i++ }
    Join-Path $dir "$stem`_v$i$ext"
}

function Get-AllStrings($node) {
    if ($null -eq $node) { return }
    if ($node -is [string]) { $node; return }
    if ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) { foreach ($x in $node) { Get-AllStrings $x }; return }
    if ($node -is [pscustomobject]) { foreach ($p in $node.PSObject.Properties) { Get-AllStrings $p.Value } }
}

Import-GlabsEnv

switch ($Action) {
    'health'     { Invoke-Glabs GET '/api/health' -NoAuth | ConvertTo-Json -Depth 10 }
    'tasks'      { Invoke-Glabs GET '/api/tasks' | ConvertTo-Json -Depth 10 }
    'characters' { Invoke-Glabs GET '/api/characters' | ConvertTo-Json -Depth 10 }
    'submit' {
        if (-not $Endpoint -or -not $BodyFile) { throw 'submit needs -Endpoint and -BodyFile' }
        $body = Expand-Body $BodyFile
        Invoke-Glabs POST "/api/$Endpoint/generate" $body | ConvertTo-Json -Depth 10
    }
    'status' { if (-not $TaskId) { throw 'need -TaskId' }; Invoke-Glabs GET "/api/status/$TaskId" | ConvertTo-Json -Depth 10 }
    'result' { if (-not $TaskId) { throw 'need -TaskId' }; Invoke-Glabs GET "/api/result/$TaskId" | ConvertTo-Json -Depth 20 }
    'stop'   { if (-not $TaskId) { throw 'need -TaskId' }; Invoke-Glabs POST "/api/stop/$TaskId" '{}' | ConvertTo-Json -Depth 10 }
    'wait' {
        if (-not $TaskId) { throw 'need -TaskId' }
        $deadline = (Get-Date).AddSeconds($TimeoutSec); $delay = 5
        while ($true) {
            $s = Invoke-Glabs GET "/api/status/$TaskId"
            Write-Host ("[{0}] status={1} progress={2}" -f (Get-Date -Format HH:mm:ss), $s.status, $s.progress)
            if ($s.status -in @('completed', 'failed', 'stopped')) { $s | ConvertTo-Json -Depth 10; break }
            if ((Get-Date) -gt $deadline) { throw "Timeout waiting for task $TaskId (last status $($s.status))" }
            Start-Sleep -Seconds $delay; $delay = [Math]::Min(30, [int]($delay * 1.5))
        }
    }
    'download' {
        if (-not $TaskId -or -not $OutDir) { throw 'download needs -TaskId and -OutDir' }
        New-Item -ItemType Directory -Force $OutDir | Out-Null
        $res = Invoke-Glabs GET "/api/result/$TaskId"
        $saved = @(); $n = 0
        foreach ($s in (Get-AllStrings $res | Select-Object -Unique)) {
            $isFileApi = $s -match '^(https?://[^/]+)?/api/files/'
            $isLocal = ($s -match '^[A-Za-z]:\\' -or $s.StartsWith('\\')) -and (Test-Path -LiteralPath $s -PathType Leaf)
            if (-not ($isFileApi -or $isLocal)) { continue }
            $n++
            $srcName = if ($isLocal) { [IO.Path]::GetFileName($s) } else { [Uri]::UnescapeDataString(($s -split '/')[-1]) }
            $ext = [IO.Path]::GetExtension($srcName); if (-not $ext) { $ext = '.bin' }
            $name = if ($BaseName) { if ($n -gt 1) { "$BaseName`_$n$ext" } else { "$BaseName$ext" } } else { $srcName }
            $dest = Get-UniquePath $OutDir $name
            if ($isLocal) { Copy-Item -LiteralPath $s $dest }
            else {
                $url = if ($s.StartsWith('http')) { $s } else { $env:GLABS_BASE_URL.TrimEnd('/') + $s }
                Invoke-WebRequest -UseBasicParsing -Uri $url -Headers (Get-Headers) -OutFile $dest
            }
            $hash = (Get-FileHash -Algorithm SHA256 $dest).Hash
            $saved += [pscustomobject]@{ file = $dest; bytes = (Get-Item $dest).Length; sha256 = $hash }
        }
        if (-not $saved) { Write-Warning 'No downloadable file found in result; raw result follows.'; $res | ConvertTo-Json -Depth 20 }
        else { $saved | ConvertTo-Json -Depth 5 }
    }
}

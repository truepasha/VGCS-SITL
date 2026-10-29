# Upload ardupilot-release.json to existing VGCS-SITL releases that lack it.
# Requires: gh auth with repo scope; network access to ArduPilot/ardupilot.
param(
    [Parameter(Mandatory = $false)]
    [string] $Repo = "truepasha/VGCS-SITL",

    [Parameter(Mandatory = $false)]
    [string] $OnlyTag = "",

    [Parameter(Mandatory = $false)]
    [switch] $WhatIf
)

$ErrorActionPreference = "Stop"

function Format-UtcIsoZ {
    param([datetimeoffset] $Value)
    return $Value.ToUniversalTime().UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
}

function Resolve-ArduPilotReleaseUtc {
    param([string] $Tag)

    $apiJson = gh api "repos/ArduPilot/ardupilot/releases/tags/$Tag" 2>$null
    if ($LASTEXITCODE -eq 0 -and $apiJson) {
        $published = ($apiJson | ConvertFrom-Json).published_at
        if (-not [string]::IsNullOrWhiteSpace($published)) {
            return @{
                Utc    = (Format-UtcIsoZ ([datetimeoffset]::Parse($published)))
                Source = "github-release"
            }
        }
    }

    # Lightweight: tip commit date for the remote tag (no full clone).
    $ls = git ls-remote --tags --refs https://github.com/ArduPilot/ardupilot.git $Tag 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ls)) {
        throw "Tag not found on ArduPilot/ardupilot: $Tag"
    }

    $sha = ($ls -split "\s+")[0]
    $commitJson = gh api "repos/ArduPilot/ardupilot/git/commits/$sha"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read commit $sha for $Tag"
    }
    $commitDate = ($commitJson | ConvertFrom-Json).committer.date
    if ([string]::IsNullOrWhiteSpace($commitDate)) {
        throw "No committer.date for $Tag ($sha)"
    }

    return @{
        Utc    = (Format-UtcIsoZ ([datetimeoffset]::Parse($commitDate)))
        Source = "git-commit"
    }
}

function Parse-VehicleTag {
    param([string] $Tag)
    if ($Tag -notmatch '^(Copter|Plane|Rover|Sub)-(\d+\.\d+\.\d+)$') {
        return $null
    }
    return @{ Vehicle = $Matches[1]; Version = $Matches[2] }
}

$releasesJson = gh api "repos/$Repo/releases?per_page=100" --paginate
if ($LASTEXITCODE -ne 0) {
    throw "Failed to list releases for $Repo"
}

# --paginate may emit multiple JSON arrays; normalize to one list.
$releases = @()
foreach ($chunk in ($releasesJson | ConvertFrom-Json)) {
    if ($chunk -is [System.Array]) {
        $releases += $chunk
    }
    else {
        $releases += @($chunk)
    }
}

$work = Join-Path $env:TEMP ("vgcs-sitl-backfill-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null

try {
    $updated = 0
    $skipped = 0
    foreach ($release in $releases) {
        $tag = [string]$release.tag_name
        if ([string]::IsNullOrWhiteSpace($tag)) {
            continue
        }
        if ($OnlyTag -and -not $tag.Equals($OnlyTag, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $parsed = Parse-VehicleTag -Tag $tag
        if (-not $parsed) {
            Write-Host "skip (non-vehicle tag): $tag"
            $skipped++
            continue
        }

        $hasManifest = @($release.assets) |
            Where-Object { $_.name -eq "ardupilot-release.json" } |
            Select-Object -First 1
        if ($hasManifest) {
            Write-Host "skip (already has manifest): $tag"
            $skipped++
            continue
        }

        $info = Resolve-ArduPilotReleaseUtc -Tag $tag
        $manifest = [ordered]@{
            upstreamTag            = $tag
            vehicle                = $parsed.Vehicle
            version                = $parsed.Version
            ardupilotReleaseUtc    = $info.Utc
            ardupilotReleaseSource = $info.Source
        }
        $path = Join-Path $work "ardupilot-release.json"
        $json = ($manifest | ConvertTo-Json -Depth 5) + "`n"
        [IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding $false))

        Write-Host "manifest $tag -> $($info.Utc) ($($info.Source))"
        if ($WhatIf) {
            Write-Host "  (WhatIf) would upload $path"
            $updated++
            continue
        }

        gh release upload $tag $path --repo $Repo --clobber
        if ($LASTEXITCODE -ne 0) {
            throw "Upload failed for $tag"
        }
        $updated++
    }

    Write-Host "Done. updated=$updated skipped=$skipped"
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

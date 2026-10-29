# Ensure VGCS-SITL release notes contain: ArduPilot-Release-Date: yyyy-MM-dd
# Does not upload ardupilot-release.json. Requires: gh auth with repo scope.
param(
    [Parameter(Mandatory = $false)]
    [string] $Repo = "truepasha/VGCS-SITL",

    [Parameter(Mandatory = $false)]
    [string] $OnlyTag = "",

    [Parameter(Mandatory = $false)]
    [switch] $WhatIf
)

$ErrorActionPreference = "Stop"

$DateLinePrefix = "ArduPilot-Release-Date:"

function Format-UtcDateOnly {
    param([datetimeoffset] $Value)
    return $Value.ToUniversalTime().UtcDateTime.ToString("yyyy-MM-dd")
}

function Resolve-ArduPilotReleaseDate {
    param([string] $Tag)

    # Some ArduPilot tags are not GitHub "Releases" (404) — fall through to commit date.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $apiJson = gh api "repos/ArduPilot/ardupilot/releases/tags/$Tag" 2>$null
        if ($LASTEXITCODE -eq 0 -and $apiJson) {
            $published = ($apiJson | ConvertFrom-Json).published_at
            if (-not [string]::IsNullOrWhiteSpace($published)) {
                return @{
                    Date   = (Format-UtcDateOnly ([datetimeoffset]::Parse($published)))
                    Source = "github-release"
                }
            }
        }
    }
    finally {
        $ErrorActionPreference = $prevEap
    }

    $ErrorActionPreference = "Continue"
    try {
        $ls = git ls-remote --tags --refs https://github.com/ArduPilot/ardupilot.git $Tag 2>$null
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ls)) {
        throw "Tag not found on ArduPilot/ardupilot: $Tag"
    }

    $sha = ($ls -split "\s+")[0]
    $ErrorActionPreference = "Continue"
    try {
        $commitJson = gh api "repos/ArduPilot/ardupilot/git/commits/$sha" 2>$null
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commitJson)) {
        throw "Failed to read commit $sha for $Tag"
    }
    $commitDate = ($commitJson | ConvertFrom-Json).committer.date
    if ([string]::IsNullOrWhiteSpace($commitDate)) {
        throw "No committer.date for $Tag ($sha)"
    }

    return @{
        Date   = (Format-UtcDateOnly ([datetimeoffset]::Parse($commitDate)))
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

function Ensure-ReleaseDateLine {
    param(
        [string] $Body,
        [string] $Date
    )

    $line = "$DateLinePrefix $Date"
    if ([string]::IsNullOrWhiteSpace($Body)) {
        return $line + "`n"
    }

    if ($Body -match "(?m)^ArduPilot-Release-Date:\s*\d{4}-\d{2}-\d{2}\s*$") {
        return [regex]::Replace(
            $Body,
            "(?m)^ArduPilot-Release-Date:\s*\d{4}-\d{2}-\d{2}\s*$",
            $line)
    }

    return $Body.TrimEnd() + "`n`n" + $line + "`n"
}

$releasesJson = gh api "repos/$Repo/releases?per_page=100" --paginate
if ($LASTEXITCODE -ne 0) {
    throw "Failed to list releases for $Repo"
}

$releases = @()
foreach ($chunk in ($releasesJson | ConvertFrom-Json)) {
    if ($chunk -is [System.Array]) {
        $releases += $chunk
    }
    else {
        $releases += @($chunk)
    }
}

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

    $body = [string]$release.body
    if ($body -match "(?m)^ArduPilot-Release-Date:\s*(\d{4}-\d{2}-\d{2})\s*$") {
        Write-Host "skip (already has date line $($Matches[1])): $tag"
        $skipped++
        continue
    }

    $info = Resolve-ArduPilotReleaseDate -Tag $tag
    $newBody = Ensure-ReleaseDateLine -Body $body -Date $info.Date
    Write-Host "notes $tag -> $($info.Date) ($($info.Source))"
    if ($WhatIf) {
        Write-Host "  (WhatIf) would edit release notes"
        $updated++
        continue
    }

    $notesFile = Join-Path $env:TEMP ("vgcs-sitl-notes-" + [guid]::NewGuid().ToString("N") + ".md")
    try {
        [IO.File]::WriteAllText($notesFile, $newBody, (New-Object System.Text.UTF8Encoding $false))
        gh release edit $tag --repo $Repo --notes-file $notesFile
        if ($LASTEXITCODE -ne 0) {
            throw "gh release edit failed for $tag"
        }
    }
    finally {
        Remove-Item -LiteralPath $notesFile -Force -ErrorAction SilentlyContinue
    }

    $updated++
}

Write-Host "Done. updated=$updated skipped=$skipped"

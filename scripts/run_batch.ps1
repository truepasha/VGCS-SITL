# Build and publish one or more ArduPilot SITL tags on a prepared Cygwin host.
param(
    [Parameter(Mandatory = $true)]
    [string] $TagsJson,

    [Parameter(Mandatory = $true)]
    [string] $Workspace,

    [Parameter(Mandatory = $true)]
    [string] $Repo
)

$ErrorActionPreference = "Stop"

$parsed = $TagsJson | ConvertFrom-Json
$tags = @($parsed)
if ($tags.Count -eq 0) {
    Write-Host "No tags in batch."
    exit 0
}

$bash = "C:\cygwin\bin\bash.exe"
if (-not (Test-Path $bash)) {
    throw "Cygwin bash not found at $bash"
}

New-Item -ItemType Directory -Force -Path "C:\ccache-sitl" | Out-Null

$wsUnix = ($Workspace -replace "\\", "/")
$scriptsUnix = (& $bash -lc "cygpath -u '$wsUnix/vgcs-sitl/scripts'").Trim()
$ccacheUnix = (& $bash -lc "cygpath -u 'C:/ccache-sitl'").Trim()

foreach ($item in $tags) {
    $tag = [string]$item.tag
    $waf = [string]$item.waf_target
    $artifact = [string]$item.artifact_name
    $binary = [string]$item.binary_name
    $vehicle = [string]$item.vehicle
    $version = [string]$item.version

    Write-Host "======== Building $tag ========"

    $src = Join-Path $Workspace "ardupilot-src"
    if (Test-Path $src) {
        Remove-Item -Recurse -Force $src
    }

    git clone --depth 1 --branch $tag --recurse-submodules `
        https://github.com/ArduPilot/ardupilot.git $src
    if ($LASTEXITCODE -ne 0) {
        throw "git clone failed for $tag"
    }

    $srcUnix = (& $bash -lc "cygpath -u '$($src -replace '\\','/')'").Trim()

    # Literal bash script (avoid PowerShell expanding $(...) / ${...}).
    $runnerBody = @'
#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:$(cygpath "${SYSTEMROOT}")/system32"
export GITHUB_ACTIONS=true
export CCACHE_DIR="__CCACHE_DIR__"
export CCACHE_COMPRESS=1
export CCACHE_MAXSIZE=2G
export PYTHON_BIN=python3.9
git config --global --add safe.directory "__SRC_DIR__"
cd "__SRC_DIR__"
bash "__SCRIPTS_DIR__/build_sitl_vehicle.sh" "__WAF__" "__ARTIFACT__" "__BINARY__"
'@
    $runnerBody = $runnerBody.
        Replace("__CCACHE_DIR__", $ccacheUnix).
        Replace("__SRC_DIR__", $srcUnix).
        Replace("__SCRIPTS_DIR__", $scriptsUnix).
        Replace("__WAF__", $waf).
        Replace("__ARTIFACT__", $artifact).
        Replace("__BINARY__", $binary)

    $runner = Join-Path $Workspace "run-one-build.sh"
    [IO.File]::WriteAllText(
        $runner,
        ($runnerBody -replace "`r`n", "`n" -replace "`r", "`n"),
        (New-Object System.Text.UTF8Encoding $false))

    $runnerUnix = (& $bash -lc "cygpath -u '$($runner -replace '\\','/')'").Trim()
    & $bash -eo pipefail "$runnerUnix"
    if ($LASTEXITCODE -ne 0) {
        throw "Build failed for $tag"
    }

    $artifacts = Join-Path $src "artifacts"
    if (-not (Test-Path $artifacts)) {
        throw "No artifacts directory for $tag"
    }

    $primary = Join-Path $artifacts $artifact
    if (-not (Test-Path -LiteralPath $primary)) {
        Write-Host "Artifacts present:"
        Get-ChildItem -LiteralPath $artifacts | Format-Table Name, Length
        throw "Primary SITL binary missing after build: $primary"
    }

    # Windows Process.Start is happier with .exe; keep .elf for MP-compatible layout.
    $exeName = [IO.Path]::ChangeExtension($artifact, ".exe")
    if ([string]::IsNullOrWhiteSpace($exeName) -or $exeName -eq $artifact) {
        $exeName = "$artifact.exe"
    }
    $exePath = Join-Path $artifacts $exeName
    Copy-Item -LiteralPath $primary -Destination $exePath -Force

    Write-Host "Staging release files:"
    Get-ChildItem -LiteralPath $artifacts -File | Format-Table Name, Length

    $notes = @"
Windows (Cygwin) SITL build for ArduPilot **$tag**.

| Field | Value |
| --- | --- |
| Vehicle | $vehicle |
| Version | $version |
| Upstream | https://github.com/ArduPilot/ardupilot/tree/$tag |
| Primary binary | ``$artifact`` (also ``$exeName``) |

Runtime ``cyg*.dll`` files are included next to the binary (Mission Planner layout).

Source: ArduPilot (GPLv3). Built by [$Repo](https://github.com/$Repo).
"@

    $files = @(Get-ChildItem -LiteralPath $artifacts -File | ForEach-Object { $_.FullName })
    if ($files.Count -eq 0) {
        throw "Artifacts folder empty for $tag"
    }
    if (-not ($files | Where-Object { $_.EndsWith($artifact, [StringComparison]::OrdinalIgnoreCase) })) {
        throw "Primary artifact not in upload list: $artifact"
    }

    gh release view $tag --repo $Repo 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        gh release delete $tag --repo $Repo --yes
        git push "https://x-access-token:$($env:GITHUB_TOKEN)@github.com/$Repo.git" ":refs/tags/$tag" 2>$null
    }

    # Create release first, then upload assets one-by-one so a missing .elf fails the job.
    gh release create $tag `
        --repo $Repo `
        --title $tag `
        --notes $notes
    if ($LASTEXITCODE -ne 0) {
        throw "gh release create failed for $tag"
    }

    foreach ($file in $files) {
        Write-Host "Uploading $(Split-Path $file -Leaf) ..."
        gh release upload $tag $file --repo $Repo --clobber
        if ($LASTEXITCODE -ne 0) {
            throw "gh release upload failed for $file"
        }
    }

    $uploaded = gh api "repos/$Repo/releases/tags/$tag" --jq "[.assets[].name] | join(\", \")"
    if ($uploaded -notmatch [regex]::Escape($artifact)) {
        throw "Release $tag is missing primary asset $artifact. Uploaded: $uploaded"
    }

    Write-Host "Published release $tag ($uploaded)"
}

Write-Host "Batch complete ($($tags.Count) tag(s))."

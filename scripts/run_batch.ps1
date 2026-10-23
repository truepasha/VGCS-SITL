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

function Find-SitlBuildBinary {
    param(
        [string] $SrcRoot,
        [string] $BinaryName
    )

    $candidates = @(
        (Join-Path $SrcRoot "build\sitl\bin\$BinaryName.exe"),
        (Join-Path $SrcRoot "build\sitl\bin\$BinaryName"),
        (Join-Path $SrcRoot "artifacts\sitl_payload.bin"),
        (Join-Path $SrcRoot "artifacts\$BinaryName.exe"),
        (Join-Path $SrcRoot "artifacts\$BinaryName")
    )

    # Cygwin may have written ArduPlane.elf as ArduPlane.elf.exe
    $artifactsDir = Join-Path $SrcRoot "artifacts"
    if (Test-Path -LiteralPath $artifactsDir) {
        $candidates += @(Get-ChildItem -LiteralPath $artifactsDir -File -Filter "*.elf.exe" |
            ForEach-Object { $_.FullName })
        $candidates += @(Get-ChildItem -LiteralPath $artifactsDir -File -Filter "*.exe" |
            Where-Object { $_.Name -like "Ardu*" } |
            ForEach-Object { $_.FullName })
    }

    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Length -gt 0)) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    return $null
}

function Stage-ReleaseBinaries {
    param(
        [string] $ArtifactsDir,
        [string] $SourceBinary,
        [string] $ElfName
    )

    $exeName = [IO.Path]::ChangeExtension($ElfName, ".exe")
    if ([string]::IsNullOrWhiteSpace($exeName) -or $exeName -eq $ElfName) {
        $exeName = "$ElfName.exe"
    }

    $elfPath = Join-Path $ArtifactsDir $ElfName
    $exePath = Join-Path $ArtifactsDir $exeName
    $mangledElfExe = Join-Path $ArtifactsDir ($ElfName + ".exe") # ArduPlane.elf.exe

    # System.IO.File.Copy does not apply Cygwin PE→.exe renaming.
    [IO.File]::Copy($SourceBinary, $elfPath, $true)
    [IO.File]::Copy($SourceBinary, $exePath, $true)

    if ((Test-Path -LiteralPath $mangledElfExe) -and
        ($mangledElfExe -ne $exePath) -and
        ($mangledElfExe -ne $elfPath)) {
        Remove-Item -LiteralPath $mangledElfExe -Force
    }

    # Drop helper markers from the release upload set.
    foreach ($helper in @("binary-source.txt", "artifact-name.txt", "sitl_payload.bin", "_vgcs_cygcheck_probe.exe")) {
        $helperPath = Join-Path $ArtifactsDir $helper
        if (Test-Path -LiteralPath $helperPath) {
            Remove-Item -LiteralPath $helperPath -Force
        }
    }

    if (-not (Test-Path -LiteralPath $elfPath) -or (Get-Item -LiteralPath $elfPath).Length -le 0) {
        throw "Failed to stage ELF via File.Copy: $elfPath"
    }
    if (-not (Test-Path -LiteralPath $exePath) -or (Get-Item -LiteralPath $exePath).Length -le 0) {
        throw "Failed to stage EXE via File.Copy: $exePath"
    }

    return @{ Elf = $elfPath; Exe = $exePath; ElfName = $ElfName; ExeName = $exeName }
}

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

    $sourceBinary = $null
    $binarySourceFile = Join-Path $artifacts "binary-source.txt"
    if (Test-Path -LiteralPath $binarySourceFile) {
        $rel = (Get-Content -LiteralPath $binarySourceFile -Raw).Trim()
        if ($rel) {
            $candidate = Join-Path $src ($rel -replace "/", "\")
            if (Test-Path -LiteralPath $candidate) {
                $sourceBinary = (Resolve-Path -LiteralPath $candidate).Path
            }
        }
    }
    if (-not $sourceBinary) {
        $sourceBinary = Find-SitlBuildBinary -SrcRoot $src -BinaryName $binary
    }
    if (-not $sourceBinary) {
        Write-Host "build/sitl/bin:"
        $binDir = Join-Path $src "build\sitl\bin"
        if (Test-Path $binDir) { Get-ChildItem $binDir | Format-Table Name, Length }
        Write-Host "artifacts:"
        Get-ChildItem -LiteralPath $artifacts | Format-Table Name, Length
        throw "Could not locate compiled SITL binary for $tag ($binary)"
    }

    Write-Host "Using build binary: $sourceBinary ($((Get-Item -LiteralPath $sourceBinary).Length) bytes)"
    $staged = Stage-ReleaseBinaries -ArtifactsDir $artifacts -SourceBinary $sourceBinary -ElfName $artifact

    Write-Host "Staging release files:"
    Get-ChildItem -LiteralPath $artifacts -File | Format-Table Name, Length

    $notes = @"
Windows (Cygwin) SITL build for ArduPilot **$tag**.

| Field | Value |
| --- | --- |
| Vehicle | $vehicle |
| Version | $version |
| Upstream | https://github.com/ArduPilot/ardupilot/tree/$tag |
| Primary binary | ``$($staged.ElfName)`` (also ``$($staged.ExeName)``) |

Runtime ``cyg*.dll`` files are included next to the binary (Mission Planner layout).

Source: ArduPilot (GPLv3). Built by [$Repo](https://github.com/$Repo).
"@

    $uploadNames = @(Get-ChildItem -LiteralPath $artifacts -File | ForEach-Object { $_.Name })
    if ($uploadNames -notcontains $staged.ElfName) {
        throw "Staged ELF missing from artifacts listing: $($staged.ElfName). Have: $($uploadNames -join ', ')"
    }
    if ($uploadNames -notcontains $staged.ExeName) {
        throw "Staged EXE missing from artifacts listing: $($staged.ExeName). Have: $($uploadNames -join ', ')"
    }

    $files = @(Get-ChildItem -LiteralPath $artifacts -File | ForEach-Object { $_.FullName })

    gh release view $tag --repo $Repo 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        gh release delete $tag --repo $Repo --yes
        git push "https://x-access-token:$($env:GITHUB_TOKEN)@github.com/$Repo.git" ":refs/tags/$tag" 2>$null
    }

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
    if ($uploaded -notmatch [regex]::Escape($staged.ElfName)) {
        throw "Release $tag is missing $($staged.ElfName). Uploaded: $uploaded"
    }
    if ($uploaded -notmatch [regex]::Escape($staged.ExeName)) {
        throw "Release $tag is missing $($staged.ExeName). Uploaded: $uploaded"
    }

    Write-Host "Published release $tag ($uploaded)"
}

Write-Host "Batch complete ($($tags.Count) tag(s))."

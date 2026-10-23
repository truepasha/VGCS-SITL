# Offline proof that System.IO.File.Copy keeps the exact .elf name (unlike Cygwin cp).
$ErrorActionPreference = "Stop"
$root = Join-Path $env:TEMP ("vgcs-sitl-stage-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $src = Join-Path $root "payload.bin"
    [IO.File]::WriteAllBytes($src, [byte[]](0x4D, 0x5A, 0x90, 0x00)) # MZ header stub

    $elf = Join-Path $root "ArduPlane.elf"
    $exe = Join-Path $root "ArduPlane.exe"
    [IO.File]::Copy($src, $elf, $true)
    [IO.File]::Copy($src, $exe, $true)

    if (-not (Test-Path -LiteralPath $elf)) { throw "ELF missing" }
    if (-not (Test-Path -LiteralPath $exe)) { throw "EXE missing" }
    if (Test-Path -LiteralPath ($elf + ".exe")) { throw "Unexpected mangled .elf.exe appeared" }

    Write-Host "ok: File.Copy preserves ArduPlane.elf and ArduPlane.exe"
}
finally {
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

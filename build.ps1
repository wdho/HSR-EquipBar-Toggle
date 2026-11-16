param(
    [string]$Gcc = 'gcc.exe',
    [string]$Objdump
)

$ErrorActionPreference = 'Stop'

$compiler = (Get-Command $Gcc -CommandType Application).Source
$machine = & $compiler -dumpmachine
if ($LASTEXITCODE -ne 0 -or "$machine" -cne 'x86_64-w64-mingw32') {
    throw "Expected x86_64-w64-mingw32 GCC, got '$machine' from $compiler"
}
if (-not $Objdump) {
    $compilerName = Split-Path -Leaf $compiler
    $objdumpName = if ($compilerName -like 'x86_64-w64-mingw32-*') {
        'x86_64-w64-mingw32-objdump.exe'
    } else {
        'objdump.exe'
    }
    $Objdump = Join-Path (Split-Path -Parent $compiler) $objdumpName
}
$Objdump = (Get-Command $Objdump -CommandType Application).Source

$src = Join-Path $PSScriptRoot 'native'
$def = Join-Path $src 'xluau.def'
$files = @(Get-ChildItem -LiteralPath $src -Filter '*.c' -File | Sort-Object Name)
if (-not $files.Count) { throw "No C sources in $src" }
if (-not (Test-Path -LiteralPath $def -PathType Leaf)) { throw "Missing $def" }

$out = Join-Path $PSScriptRoot 'out'
$stage = Join-Path $out ('build-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$stagedDll = Join-Path $stage 'xluau.dll'
$dll = Join-Path $out 'xluau.dll'
try {
    $argsForGcc = @('-shared', '-O2', '-municode', '-fno-strict-aliasing', '-DUNICODE',
                    '-D_UNICODE', '-o', $stagedDll) + @($files.FullName) +
                  @($def, '-Wl,--kill-at', '-lkernel32', '-luser32', '-lgdi32', '-ladvapi32')
    & $compiler @argsForGcc
    if ($LASTEXITCODE -ne 0) { throw "GCC failed with exit code $LASTEXITCODE" }

    & (Join-Path $PSScriptRoot 'tools/verify-exports.ps1') -Dll $stagedDll -Def $def -Objdump $Objdump
    Move-Item -LiteralPath $stagedDll -Destination $dll -Force
    $artifact = Get-Item -LiteralPath $dll
    Write-Host "OK: $($artifact.FullName) ($($artifact.Length) bytes)" -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $stagedDll) { Remove-Item -LiteralPath $stagedDll }
    Remove-Item -LiteralPath $stage
}
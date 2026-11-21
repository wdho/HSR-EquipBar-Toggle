param(
    [Parameter(Mandatory = $true)] [string]$Dll,
    [Parameter(Mandatory = $true)] [string]$Def,
    [string]$Objdump = 'objdump.exe'
)

$ErrorActionPreference = 'Stop'
$required = @('luaL_loadstring', 'lua_pcall', 'lua_gettop', 'lua_settop', 'lua_tolstring')
$probe = 'EquipBarNative_probe'
$expected = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
foreach ($line in Get-Content -LiteralPath $Def) {
    $entry = ($line -split ';', 2)[0].Trim()
    if (-not $entry -or $entry -match '^(?:LIBRARY\s+xluau|EXPORTS)$') { continue }
    if ($entry -cnotmatch '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(xluau_real\.[A-Za-z_][A-Za-z0-9_]*)$') {
        throw "Invalid forwarder in .def: $entry"
    }
    $name, $target = $Matches[1], $Matches[2]
    if ($target -cne "xluau_real.$name" -or $name -ceq $probe -or $expected.ContainsKey($name)) {
        throw "Invalid or duplicate forwarder in .def: $entry"
    }
    $expected.Add($name, $target)
}
if ($expected.Count -ne 218) { throw "Expected 218 forwarders in .def, got $($expected.Count)" }
foreach ($name in $required) {
    if (-not $expected.ContainsKey($name)) { throw "Required export missing from .def: $name" }
}

# Match public names to forwarder strings through their shared export address
# table index, rather than counting unique destination names.
$tool = (Get-Command $Objdump -CommandType Application).Source
$beforeLocale = $env:LC_ALL
try {
    $env:LC_ALL = 'C'
    $dump = & $tool -p $Dll
    if ($LASTEXITCODE -ne 0) { throw "objdump failed with exit code $LASTEXITCODE" }
} finally {
    $env:LC_ALL = $beforeLocale
}
$addresses = [Collections.Generic.Dictionary[int,string]]::new()
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$indices = [Collections.Generic.HashSet[int]]::new()
$mode = ''
$isX64 = $false
foreach ($line in $dump) {
    if ($line -match 'file format pei-x86-64\s*$') { $isX64 = $true }
    if ($line -match '^Export Address Table -- Ordinal Base \d+\s*$') {
        $mode = 'address'
        continue
    }
    if ($line -match '^\[Ordinal/Name Pointer\] Table(?: -- Ordinal Base \d+)?\s*$') {
        $mode = 'names'
        continue
    }
    if ($mode -and [string]::IsNullOrWhiteSpace($line)) {
        $mode = ''
        continue
    }
    if ($mode -eq 'address' -and
        $line -match '^\s*\[\s*(\d+)\]\s+\+base\[\s*\d+\]\s+0*[1-9a-fA-F][a-fA-F0-9]*\s+(?:Forwarder RVA -- (\S+)|Export RVA)\s*$') {
        $addresses.Add([int]$Matches[1], $Matches[2])
    }
    if ($mode -eq 'names' -and $line -match '^\s*\[\s*(\d+)\]\s+(?:\+base\[\s*\d+\]\s+[a-fA-F0-9]+\s+)?(\S+)\s*$') {
        $index, $name = [int]$Matches[1], $Matches[2]
        if (-not $seen.Add($name) -or -not $indices.Add($index) -or -not $addresses.ContainsKey($index)) {
            throw "Duplicate or unbound PE export: $name (address index $index)"
        }
        $actual = $addresses[$index]
        if ($name -ceq $probe) {
            if ($actual) { throw "$probe must be a local export, not a forwarder" }
        } elseif (-not $expected.ContainsKey($name)) {
            throw "Unexpected export: $name"
        } elseif ($expected[$name] -cne $actual) {
            throw "Wrong forwarder for $name ('$actual', expected '$($expected[$name])')"
        }
    }
}
if (-not $isX64) { throw "Expected a Windows x64 PE image: $Dll" }
if ($seen.Count -ne ($expected.Count + 1) -or $addresses.Count -ne $seen.Count -or -not $seen.Contains($probe)) {
    throw "Expected $($expected.Count) named forwarders and $probe; found $($seen.Count) names / $($addresses.Count) addresses"
}
Write-Host "Verified $($expected.Count) named Lua forwarders and $probe"
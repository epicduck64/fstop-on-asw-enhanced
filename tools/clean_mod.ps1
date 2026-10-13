# clean_mod.ps1 - drop redundant files from portal_template.
#
# portal_template mounts FIRST, so any file in it that is byte-identical to what
# the mounts below serve (leak, then retail) is pointless: it changes nothing and
# only adds weight. Those are removed. What stays is exactly the set of files
# that genuinely differ - the overrides.
#
# tools/clean_mod.bat [-DryRun]

[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$LeakAssets = '',
    [string]$ModPath  = 'game\portal_template',
    [string]$RetailMount = 'game\retail',
    [string[]]$LeakTrees = @('portal2','portal2_tempcontent','portal','hl2'),
    [string[]]$ExcludeExt = @('.pdb','.dll','.exe','.lib','.obj','.exp','.ilk','.idb','.tlog','.map','.log','.tmp','.dt','.sav','.cache'),
    [string[]]$ExcludeDirs = @('bin','SAVE','screenshots','soundcache'),
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$modDir    = Join-Path $RepoRoot $ModPath
$retailDir = Join-Path $RepoRoot $RetailMount
if (-not $LeakAssets) { $LeakAssets = Join-Path $RepoRoot 'game\p2-2009' }
if (-not (Test-Path $LeakAssets)) { throw "Leak assets not found: $LeakAssets" }
$LeakAssets = (Resolve-Path $LeakAssets).Path

# served copies, priority order (leak above retail)
$base = @{}
$baseDirs = New-Object System.Collections.ArrayList
foreach ($t in $LeakTrees) { $d = Join-Path $LeakAssets $t; if (Test-Path $d) { [void]$baseDirs.Add($d) } }
if (Test-Path $retailDir) { [void]$baseDirs.Add($retailDir) }
foreach ($d in $baseDirs) {
    foreach ($f in (Get-ChildItem $d -Recurse -File -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($d.Length+1).Replace('\','/').ToLowerInvariant()
        if (-not $base.ContainsKey($rel)) { $base[$rel] = $f.FullName }
    }
}
Write-Host ("base files (leak + retail): {0:N0}" -f $base.Count)

$redundant = New-Object System.Collections.ArrayList
$keptOverrides = 0; $keptOther = 0; $skippedJunk = 0
foreach ($f in (Get-ChildItem $modDir -Recurse -File -ErrorAction SilentlyContinue)) {
    $rel = $f.FullName.Substring($modDir.Length+1).Replace('\','/')
    $key = $rel.ToLowerInvariant()
    if ($ExcludeExt -contains $f.Extension.ToLowerInvariant()) { $skippedJunk++; continue }
    $skip = $false
    foreach ($d in $ExcludeDirs) { if ($rel -match "(^|/)$([regex]::Escape($d))/") { $skip = $true; break } }
    if ($skip) { $skippedJunk++; continue }

    if ($base.ContainsKey($key) -and
        (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash -eq
        (Get-FileHash -LiteralPath $base[$key] -Algorithm SHA256).Hash) {
        [void]$redundant.Add($rel)
    } elseif ($base.ContainsKey($key)) { $keptOverrides++ } else { $keptOther++ }
}

Write-Host ("redundant (identical to a served copy): {0:N0}" -f $redundant.Count)
Write-Host ("kept - overrides                      : {0:N0}" -f $keptOverrides)
Write-Host ("kept - no counterpart anywhere        : {0:N0}" -f $keptOther)
Write-Host ("ignored (build output / runtime junk) : {0:N0}" -f $skippedJunk)

if ($DryRun) {
    Write-Host ""
    Write-Host "would remove:"
    $redundant | Sort-Object | Select-Object -First 40 | ForEach-Object { "   $_" }
    if ($redundant.Count -gt 40) { Write-Host ("   ... and {0:N0} more" -f ($redundant.Count-40)) }
    Write-Host "(dry run - nothing removed)"
    return
}
$n = 0
foreach ($rel in $redundant) {
    $p = Join-Path $modDir ($rel -replace '/','\')
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; $n++ }
}
Write-Host ("removed {0:N0} redundant files from {1}" -f $n, $ModPath)

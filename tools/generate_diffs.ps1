# generate_diffs.ps1 - express the project's asset overrides.
#
# A portal_template file is an OVERRIDE only if it differs from what the mounts
# actually serve for that path. The served copy is the highest-priority provider:
#   portal_template > core/platform (never diffed against - engine content)
#   leak trees      > game/retail
# so the base for a given path is the leak copy if the leak has it, otherwise the
# retail copy. That is what makes assets like the tombstone work: the leak has no
# copy, retail does, so it diffs against retail.
#
# Files identical to their served copy are not overrides at all -> not shipped.
# Files that differ (or have no counterpart anywhere) are copied verbatim into
# diffs\, binary. Shipping the repo is: run this, commit diffs\.
#
# Fast: hash the served copy only for paths that exist in portal_template.
#
# tools/generate_diffs.bat [-DryRun]

[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$LeakAssets = '',
    [string]$ModPath  = 'game\portal_template',
    [string]$RetailMount = 'game\retail',
    [string]$DiffDir  = 'diffs',
    [string[]]$LeakTrees = @('portal2','portal2_tempcontent','portal','hl2'),
    # build outputs and runtime junk must never enter the patch set
    [string[]]$ExcludeExt = @('.pdb','.dll','.exe','.lib','.obj','.exp','.ilk','.idb','.tlog','.map','.bak','.log','.prev','.tmp','.dt','.sav','.cache'),
    [string[]]$ExcludeDirs = @('bin','SAVE','screenshots','soundcache'),
    # Files that ship through git rather than diffs\: config/scripts, plus maps
    # and text-based definitions. Maps and text files only describe where assets
    # are and their properties (lighting, entity/asset properties, material
    # parameters), so they are safe to redistribute - unlike the binary assets
    # they point at, which stay in diffs\.
    [string[]]$KeepTracked = @(
        'GameInfo.txt','*.bat','steam.inf','cfg/*','tools/*',
        'maps/*',
        '*.txt','*.vmt','*.res','*.rad','*.vmf','*.vmx','*.nav','*.prt','*.ain','*.inf','*.scr','*.ekv','*.lst'
    ),
    [switch]$ApplyIgnore,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$modDir    = Join-Path $RepoRoot $ModPath
$diffRoot  = Join-Path $RepoRoot $DiffDir
$retailDir = Join-Path $RepoRoot $RetailMount
if (-not $LeakAssets) { $LeakAssets = Join-Path $RepoRoot 'game\p2-2009' }
if (-not (Test-Path $LeakAssets)) { throw "Leak assets not found: $LeakAssets" }
$LeakAssets = (Resolve-Path $LeakAssets).Path

# base lookups, in priority order: leak first, then the retail mount.
# path (lowercase) -> file on disk, first writer wins.
$base = @{}
$baseDirs = New-Object System.Collections.ArrayList
foreach ($t in $LeakTrees) {
    $d = Join-Path $LeakAssets $t
    if (Test-Path $d) { [void]$baseDirs.Add($d) }
}
if (Test-Path $retailDir) { [void]$baseDirs.Add($retailDir) }
else { Write-Host "note: no $RetailMount yet - run build_mounts first for retail-sourced bases" -ForegroundColor Yellow }

foreach ($d in $baseDirs) {
    foreach ($f in (Get-ChildItem $d -Recurse -File -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($d.Length+1).Replace('\','/').ToLowerInvariant()
        if (-not $base.ContainsKey($rel)) { $base[$rel] = $f.FullName }
    }
}
Write-Host ("base files (leak + retail): {0:N0}" -f $base.Count)

$same = 0; $written = 0; $bytes = 0L
$manifest = New-Object System.Collections.ArrayList
foreach ($f in (Get-ChildItem $modDir -Recurse -File -ErrorAction SilentlyContinue)) {
    $rel = $f.FullName.Substring($modDir.Length+1).Replace('\','/')
    $key = $rel.ToLowerInvariant()
    if ($ExcludeExt -contains $f.Extension.ToLowerInvariant()) { continue }
    # console output never ships: console.log, and the console.log.prev a rotated run leaves
    if ($f.Name -like 'console*') { continue }
    $skip = $false
    foreach ($d in $ExcludeDirs) { if ($rel -match "(^|/)$([regex]::Escape($d))/") { $skip = $true; break } }
    if ($skip) { continue }
    # config ships through git - only the gitignored assets belong in diffs\
    foreach ($p in $KeepTracked) { if ($rel -like $p) { $skip = $true; break } }
    if ($skip) { continue }

    if ($base.ContainsKey($key)) {
        if ((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $base[$key] -Algorithm SHA256).Hash) { $same++; continue }
    }
    $written++; $bytes += $f.Length
    [void]$manifest.Add($rel)
    if ($DryRun) { continue }
    $out = Join-Path $diffRoot ($key -replace '/','\')
    $d = Split-Path $out -Parent
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Copy-Item -LiteralPath $f.FullName -Destination $out -Force
}

Write-Host ("identical to served copy (not an override) : {0,6:N0}" -f $same)
Write-Host ("overrides written                          : {0,6:N0}   ({1:N1} MB)" -f $written, ($bytes/1MB))
if (-not $DryRun) {
    [IO.File]::WriteAllLines((Join-Path $diffRoot 'manifest.txt'), $manifest, (New-Object System.Text.UTF8Encoding($false)))
    # diffs\ must mirror the current override set exactly: a stale patch would
    # resurrect a file that is no longer an override (or was deleted).
    $keep = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($rel in $manifest) { [void]$keep.Add($rel.ToLowerInvariant()) }
    $pruned = 0
    foreach ($f in (Get-ChildItem $diffRoot -Recurse -File -ErrorAction SilentlyContinue)) {
        $r = $f.FullName.Substring($diffRoot.Length+1).Replace('\','/')
        if ($r -eq 'manifest.txt') { continue }
        if (-not $keep.Contains($r.ToLowerInvariant())) { Remove-Item -LiteralPath $f.FullName -Force; $pruned++ }
    }
    if ($pruned) { Write-Host ("pruned {0:N0} stale patches" -f $pruned) }
    Write-Host ("-> {0}" -f $DiffDir)
} else { Write-Host "(dry run - nothing written)" }

# --- .gitignore block --------------------------------------------------------
# Everything diffs\ carries is reconstructed by generate_assets.bat, so it need
# not be tracked a second time in portal_template. Config files (GameInfo.txt,
# .bat, steam.inf, cfg/, tools/) stay tracked - they are not assets.
if ($ApplyIgnore) {
    # every manifest entry is a gitignored asset (config is filtered out above)
    $ignored = New-Object System.Collections.ArrayList
    foreach ($rel in $manifest) { [void]$ignored.Add('/' + $ModPath.Replace('\','/') + '/' + $rel) }
    $gi = Join-Path $RepoRoot '.gitignore'
    $startTag = '# >>> mod-overrides (generated by tools/generate_diffs.ps1 -ApplyIgnore) >>>'
    $endTag   = '# <<< mod-overrides <<<'
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $block = New-Object System.Collections.ArrayList
    [void]$block.Add($startTag)
    [void]$block.Add("# generated $stamp - $($ignored.Count) entries - do not edit by hand")
    [void]$block.Add("# portal_template assets are carried by diffs\ and restored by tools\generate_assets.bat.")
    foreach ($p in ($ignored | Sort-Object)) { [void]$block.Add($p) }
    [void]$block.Add($endTag)
    $txt = [IO.File]::ReadAllText($gi)
    $pattern = [regex]::Escape($startTag) + '(?s).*?' + [regex]::Escape($endTag)
    if ($txt -match $pattern) { $txt = [regex]::Replace($txt, $pattern, ($block -join "`r`n")) }
    else { $txt = $txt.TrimEnd() + "`r`n`r`n" + ($block -join "`r`n") + "`r`n" }
    [IO.File]::WriteAllText($gi, $txt, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("gitignore: ignoring {0:N0} mod assets (config stays tracked via git)" -f $ignored.Count)
}

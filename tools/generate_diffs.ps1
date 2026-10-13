# generate_diffs.ps1 - express the project's asset overrides.
#
# A portal_template file is an OVERRIDE only if it differs from what the game
# would actually mount for that path. The mount order is read from GameInfo.txt
# (SearchPaths, in file order) and the base for a path is the FIRST mount that
# provides it - which is how the engine itself resolves a lookup. Diffing against
# a fixed tree instead mislabels an override whenever two mounts ship different
# files under the same path, because the base is then a file the game never
# serves.
#
# Files identical to that first-mounted copy are not overrides -> not shipped.
# Files that differ, or that no mount provides at all, are copied verbatim into
# diffs\. Shipping the repo is: run this, commit diffs\.
#
# The diff describes portal_template against the game content it is layered over,
# so the mod's own mount (|gameinfo_path|) and the engine mounts (core, platform)
# are never used as bases. Retail is generated to provide no path that
# portal_template, core, platform or the leak already provide, so excluding them
# keeps this consistent with the mount it is compared against.
#
# Fast: only the mount that actually serves each path is hashed.
#
# tools/generate_diffs.bat [-DryRun]

[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$LeakAssets = '',
    [string]$ModPath  = 'game\portal_template',
    # authoritative mount order; empty -> <modDir>\GameInfo.txt
    [string]$GameInfo = '',
    # never used as a diff base: the mod itself, and the engine's own mounts
    [string[]]$SkipMounts = @('core','platform'),
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

# --- mount order, straight out of GameInfo.txt -------------------------------
# SearchPaths lists the Game mounts in resolution order. The base for a path is
# the first mount that provides it, so an override is diffed against the copy the
# game would really serve. Entries using |gameinfo_path| are the mod itself (the
# files being diffed live there) and are skipped.
if (-not $GameInfo) { $GameInfo = Join-Path $modDir 'GameInfo.txt' }
$gameRoot = Split-Path -Parent $modDir
$mounts = New-Object System.Collections.ArrayList
if (Test-Path -LiteralPath $GameInfo) {
    $inSearch = $false
    foreach ($line in [IO.File]::ReadAllLines($GameInfo)) {
        $t = $line.Trim()
        if (-not $inSearch) { if ($t -match '^SearchPaths$') { $inSearch = $true }; continue }
        if ($t -eq '}') { break }
        if ($t -match '^Game\s+(.+)$') { [void]$mounts.Add($Matches[1].Trim()) }
    }
    if ($mounts.Count -eq 0) { throw "no Game mountpoints found in $GameInfo" }
    Write-Host ("mount order (GameInfo): {0}" -f ($mounts -join ' > '))
} else {
    Write-Host "note: no GameInfo.txt - falling back to leak trees + retail" -ForegroundColor Yellow
    foreach ($t in $LeakTrees) { [void]$mounts.Add("p2-2009/$t") }
    [void]$mounts.Add('retail')
}

$baseDirs = New-Object System.Collections.ArrayList
foreach ($mp in $mounts) {
    # the mod's own mount is where the files being diffed live; core/platform are
    # engine content. Neither is a base - the diff is portal_template vs the game
    # content mounts only.
    if ($mp -like '*|gameinfo_path|*') { continue }
    $p = $mp.Replace('\','/')
    if ($SkipMounts -contains $p) { continue }
    if ($p -like 'p2-2009/*')     { $d = Join-Path $LeakAssets $p.Substring(8) }
    elseif ($p -eq 'retail')      { $d = Join-Path $RepoRoot $RetailMount }
    else                          { $d = Join-Path $gameRoot $p }
    if (Test-Path -LiteralPath $d) { [void]$baseDirs.Add($d) }
    else { Write-Host ("note: mount not present, skipped: {0}" -f $p) -ForegroundColor Yellow }
}
Write-Host ("diff bases: {0}" -f (($baseDirs | ForEach-Object { $_.Substring($RepoRoot.Length+1) }) -join ' > '))
if (-not (Test-Path -LiteralPath $retailDir)) { Write-Host ("note: no {0} yet - run build_mounts first for retail-sourced bases" -f $RetailMount) -ForegroundColor Yellow }

# path (lowercase) -> file on disk; first mount to provide it wins, so a later
# mount can never displace the copy the game actually serves.
$base = @{}
foreach ($d in $baseDirs) {
    foreach ($f in (Get-ChildItem $d -Recurse -File -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($d.Length+1).Replace('\','/').ToLowerInvariant()
        if (-not $base.ContainsKey($rel)) { $base[$rel] = $f.FullName }
    }
}
Write-Host ("base files (first occurrence per path): {0:N0}" -f $base.Count)

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

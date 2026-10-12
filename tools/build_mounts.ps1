# build_mounts.ps1 - build the retail mount.
#
# Model:
#   portal_template       SHIPPED. The project's own overrides.
#   the leak trees        MOUNTED DIRECTLY (game/p2-2009/portal2,
#                         /portal2_tempcontent, /portal, /hl2). Never copied -
#                         leaking them into a generated tree was pointless work.
#                         They sit above retail, so leak content wins over retail.
#   game/retail           GENERATED. Retail only (HL2 + Portal + Portal 2 full,
#                         plus picks) - and only the files neither
#                         portal_template, core/platform nor the leak provide.
#
# So this script copies exactly one thing: retail content that is genuinely
# missing. Nothing is ever deleted.
#
# tools/build_mounts.bat          build
# tools/build_mounts.bat -DryRun  report only

[CmdletBinding()]
param(
    [string]   $RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]   $LeakAssets = '',
    [string]   $RetailMount = 'game\retail',
    [string]   $ModPath     = 'game\portal_template',
    [string[]] $FullGames     = @('hl2','portal','portal2'),
    [string[]] $NecessaryGames = @('ep2','tf2','l4d2','csgo'),
    [string[]] $Blacklist  = @('resource/','materials/vgui/','cfg/','maps/','scenes/scenes.image'),
    [string[]] $AssetRoots = @('materials/','models/','sound/','particles/','scenes/','expressions/','scripts/'),
    [string[]] $LeakTrees = @('portal2','portal2_tempcontent','portal','hl2'),
    [string]   $PickList = '',
    [switch]   $DryRun
)

$ErrorActionPreference = 'Stop'
# Normalise first: the .bat passes "%~dp0..", which leaves a literal ".." in the
# path and would make the parent-walk used for the leak default resolve wrongly.
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$sig = 0x55AA1234
$gameRoot  = Join-Path $RepoRoot 'game'
$retailDir = Join-Path $RepoRoot $RetailMount
$modDir    = Join-Path $RepoRoot $ModPath

if (-not $PickList) { $PickList = Join-Path $RepoRoot 'tools\retail_picks.txt' }
if (-not $LeakAssets) { $LeakAssets = Join-Path $RepoRoot 'game\p2-2009' }
if (-not (Test-Path $LeakAssets)) { throw "Leak assets not found: $LeakAssets (place the leak and pass -LeakAssets)" }
$LeakAssets = (Resolve-Path $LeakAssets).Path

function Get-VpkEntries([string]$vpk, [string]$OnlyPrefix = '') {
    # Parse only the directory tree. It sits at the end of the pak and is small
    # (megabytes at most); the payloads the entries point at are read later, at
    # write time. Reading the whole file to enumerate names was most of a run's
    # index cost, and it is gigabytes for the larger paks.
    $res = New-Object System.Collections.ArrayList
    $fs = [IO.File]::OpenRead($vpk)
    try {
        $h = New-Object byte[] 28
        $hn = $fs.Read($h, 0, 28)
        if ($hn -lt 12 -or [BitConverter]::ToUInt32($h,0) -ne $sig) { return $res }
        $ver = [BitConverter]::ToUInt32($h,4); $treeSize = [BitConverter]::ToUInt32($h,8)
        $hdr = 12; if ($ver -ge 2) { $hdr = 28 }
        $b = New-Object byte[] $treeSize
        [void]$fs.Seek($hdr, [IO.SeekOrigin]::Begin)
        $got = 0
        while ($got -lt $treeSize) { $n = $fs.Read($b, $got, $treeSize - $got); if ($n -le 0) { break }; $got += $n }
    } finally { $fs.Close() }

    $pos = 0; $end = $got
    while ($pos -lt $end) {
        $s=$pos; while ($pos -lt $end -and $b[$pos] -ne 0) { $pos++ }
        $ext=[Text.Encoding]::ASCII.GetString($b,$s,$pos-$s); $pos++
        if ($ext -eq '') { break }
        while ($pos -lt $end) {
            $s=$pos; while ($pos -lt $end -and $b[$pos] -ne 0) { $pos++ }
            $pth=[Text.Encoding]::ASCII.GetString($b,$s,$pos-$s); $pos++
            if ($pth -eq '') { break }
            while ($pos -lt $end) {
                $s=$pos; while ($pos -lt $end -and $b[$pos] -ne 0) { $pos++ }
                $nm=[Text.Encoding]::ASCII.GetString($b,$s,$pos-$s); $pos++
                if ($nm -eq '') { break }
                $pre=[BitConverter]::ToUInt16($b,$pos+4); $arch=[BitConverter]::ToUInt16($b,$pos+6)
                $off=[BitConverter]::ToUInt32($b,$pos+8); $len=[BitConverter]::ToUInt32($b,$pos+12)
                $pos += 16
                # VPK v1 keeps the preload bytes inline and they are the file's first
                # bytes, so they are written. VPK v2 (HL2 / Portal / Portal 2 retail,
                # L4D2, CS:GO) stores them in a separate region instead, which leaves
                # the entry terminator (FF FF) sitting here: capturing it prepended two
                # bogus bytes to ~2000 extracted .vmt/.res files, which then failed with
                # "uses unknown shader". Step over the field to stay aligned, but do not
                # treat it as content for v2.
                $pd=$null
                if ($pre -gt 0) {
                    if ($ver -lt 2) { $pd=$b[$pos..($pos+$pre-1)] }
                    $pos += $pre
                }
                $pos += 2
                # A named lookup (a pick) skips the object entirely unless the full
                # path matches, which is what keeps a one-file pick from materialising
                # hundreds of thousands of entries it will never look at. Compare the
                # assembled path including the extension - the tree stores the name
                # and the extension separately, and a pick may name either.
                $full = if ($pth -eq ' ') { "$nm.$ext" } else { "$pth/$nm.$ext" }
                if ($OnlyPrefix -and $full -notlike "$OnlyPrefix*") { continue }
                [void]$res.Add([pscustomobject]@{ Path=$full; Vpk=$vpk; Arch=$arch; Off=$off; Len=$len; Pre=$pd })
            }
        }
    }
    return $res
}

# A full game's index is what a run spends its time on, and it does not change
# unless the pak does, so it is cached beside the mount output. The tag in the
# cache file name is the pak's size and write time; a mismatch means the pak was
# updated, and the stale file is dropped. Picks never come through here - they
# are looked up with -OnlyPrefix and never materialise a full index.
function Get-VpkEntriesCached([string]$vpk, [string]$cacheDir) {
    $fi = Get-Item -LiteralPath $vpk
    if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
    $stem = ($fi.Name -replace '[^A-Za-z0-9._-]','_')
    $map  = @{ Path=$true; Arch=$true; Off=$true; Len=$true; Pre=$true }
    $tag  = '{0}_{1}' -f $fi.Length, $fi.LastWriteTimeUtc.Ticks
    $hit  = Get-ChildItem $cacheDir -Filter "$stem`_$tag.csv" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $hit) {
        Get-ChildItem $cacheDir -Filter "$stem`_*.csv" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        $fresh = Get-VpkEntries $vpk
        $fresh |
            Select-Object Path, Arch, Off, Len, @{n='Pre';e={ if ($_.Pre) { [Convert]::ToBase64String($_.Pre) } else { '' } }} |
            Export-Csv -LiteralPath (Join-Path $cacheDir "$stem`_$tag.csv") -NoTypeInformation -Encoding UTF8
        return $fresh
    }
    $res = New-Object System.Collections.ArrayList
    foreach ($r in (Import-Csv -LiteralPath $hit.FullName)) {
        [void]$res.Add([pscustomobject]@{
            Path = $r.Path; Vpk = $vpk; Arch = [int]$r.Arch; Off = [long]$r.Off; Len = [int]$r.Len
            Pre  = $(if ($r.Pre) { [Convert]::FromBase64String($r.Pre) } else { $null })
        })
    }
    return $res
}
function Test-Asset([string]$rel) {
    $l = $rel.ToLowerInvariant()
    foreach ($r in $AssetRoots) { if ($l.StartsWith($r.ToLowerInvariant())) { return $true } }
    return $false
}
function Test-Blacklisted([string]$rel) {
    $l = $rel.ToLowerInvariant()
    foreach ($x in $Blacklist) { if ($l.StartsWith($x.ToLowerInvariant())) { return $true } }
    return $false
}
function Write-Entry($src, [string]$outPath) {
    $d = Split-Path $outPath -Parent
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    if ($src.Kind -ne 'vpk') { Copy-Item -LiteralPath $src.Full -Destination $outPath -Force; return }
    $chunk = if ($src.Arch -eq 0x7FFF) { $src.Vpk } else { [regex]::Replace($src.Vpk,'_dir\.vpk$',('_{0:D3}.vpk' -f $src.Arch)) }
    $inFs = [IO.File]::OpenRead($chunk); $outFs = [IO.File]::Create($outPath)
    try {
        if ($src.Pre) { $outFs.Write($src.Pre,0,$src.Pre.Length) }
        [void]$inFs.Seek([long]$src.Off,[IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] (1MB); $left = [long]$src.Len
        while ($left -gt 0) { $want=[int][Math]::Min($buf.Length,$left); $n=$inFs.Read($buf,0,$want); if ($n -le 0){break}; $outFs.Write($buf,0,$n); $left-=$n }
    } finally { $inFs.Close(); $outFs.Close() }
}
function Get-Size($src) {
    $p = 0; if ($src.Pre) { $p = $src.Pre.Length }
    return ($p + [long]$src.Len)
}

# A path at or past MAX_PATH (260) fails in Copy-Item and the IO APIs unless it
# carries the \\?\ prefix, which opts out of the limit. Only absolute paths can
# take it, and every path built here is absolute.
function Get-LongPath([string]$p) {
    if ($p.Length -ge 240 -and -not $p.StartsWith('\\?\')) { return '\\?\' + $p }
    return $p
}

# ----------------------------------------------------- install index --------
# Only scan what can actually be used: the full games, plus any game named by a
# pick. Indexing CS:GO/L4D2/TF2 wholesale is tens of thousands of entries of
# pure waste otherwise.
$needGames = New-Object 'System.Collections.Generic.HashSet[string]'
# Per-game pick paths, so a game that is only being scanned because a pick names
# it can be looked up by name instead of having its whole pak indexed.
$pickByGame = @{}
foreach ($g in $FullGames) { [void]$needGames.Add($g.ToLowerInvariant()) }
if (Test-Path $PickList) {
    foreach ($l in (Get-Content $PickList)) {
        if ($l -match '^\s*([A-Za-z0-9]+)\s*:\s*(.+)$') {
            $pg = $matches[1].ToLowerInvariant(); $pp = $matches[2].Trim().ToLowerInvariant()
            [void]$needGames.Add($pg)
            if (-not $pickByGame.ContainsKey($pg)) { $pickByGame[$pg] = New-Object System.Collections.ArrayList }
            [void]$pickByGame[$pg].Add($pp)
        }
    }
}
Write-Host ("== retail sources (scanning: {0}) ==" -f (($needGames | Sort-Object) -join ', ')) -ForegroundColor Cyan

# --- locate the retail installs through Steam --------------------------------
# HKCU registry -> Steam root -> steamapps -> libraryfolders.vdf -> per-library
# appmanifest_<appid>.acf. The manifest is the source of truth: it gives the real
# install folder name (which need not match the title) and a StateFlags gate, and
# it is the only way to find a game moved to a different library/drive.
$appIds = @{ hl2='220'; ep2='420'; portal='400'; portal2='620'; tf='440'; l4d2='550'; csgo='730' }
# game content lives in a subdir of the install; EP2 in particular shares the
# "Half-Life 2" install with HL2, so scanning the install root would make the
# two games index the same files. CS:GO's content sits in the install's csgo\
# (that is the `csgo` beta branch the README points at; CS2 uses game\csgo,
# which we do not target - a CS2-only install simply falls back to the root).
$gameSubdir = @{ hl2='hl2'; ep2='ep2'; portal='portal'; portal2='portal2'; tf='tf'; l4d2='left4dead2'; csgo='csgo' }
function Get-SteamLibraries {
    $steam = $null
    try { $steam = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch {}
    if (-not $steam) { $steam = 'C:\Program Files (x86)\Steam' }
    $steam = ($steam -replace '/','\').TrimEnd('\')      # registry returns forward slashes
    $libs = New-Object System.Collections.ArrayList
    if (Test-Path $steam) { [void]$libs.Add($steam) }
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        $txt = Get-Content $vdf -Raw
        foreach ($m in [regex]::Matches($txt, '"path"\s+"([^"]+)"')) {
            $p = ($m.Groups[1].Value -replace '\\\\','\').TrimEnd('\')
            if (-not (Test-Path $p)) { continue }
            $dupe = $false
            foreach ($e in $libs) { if ($e -ieq $p) { $dupe = $true; break } }   # registry case differs
            if (-not $dupe) { [void]$libs.Add($p) }
        }
    }
    return $libs
}
function Get-SteamInstall([string]$appid, $libs) {
    foreach ($lib in $libs) {
        $man = Join-Path $lib "steamapps\appmanifest_$appid.acf"
        if (-not (Test-Path $man)) { continue }
        $t = Get-Content $man -Raw
        $sf = [regex]::Match($t, '"StateFlags"\s+"([^"]+)"').Groups[1].Value
        if ($sf -and ([int]$sf -band 4) -eq 0) { continue }        # not fully installed
        $d = [regex]::Match($t, '"installdir"\s+"([^"]+)"').Groups[1].Value
        $full = Join-Path $lib "steamapps\common\$d"
        if (Test-Path $full) { return $full }
    }
    return $null
}

$libraries = Get-SteamLibraries
Write-Host ("  steam libraries: {0}" -f ($libraries -join ' ; '))
$index = @{}
foreach ($g in ($needGames | Sort-Object)) {
    $appid = $appIds[$g]
    if (-not $appid) { Write-Host ("  {0,-6} no app id mapped - skipped" -f $g) -ForegroundColor Yellow; continue }
    $dir = Get-SteamInstall $appid $libraries
    if (-not $dir) { Write-Host ("  {0,-6} not installed" -f $g) -ForegroundColor Yellow; continue }
    $sub = $gameSubdir[$g]
    if ($sub) { $cand = Join-Path $dir $sub; if (Test-Path $cand) { $dir = $cand } }
    $n = 0; $loose = 0
    # Full games: index everything, through the on-disk cache so a re-run does not
    # re-parse unchanged paks. Pick-only games (EP2/TF2/L4D2/CS:GO): never build a
    # full index - look the named paths up instead, which is what keeps a one-file
    # pick from scanning the whole pak database.
    $isFull = $FullGames -contains $g
    $prefixes = @()
    if (-not $isFull -and $pickByGame.ContainsKey($g)) { $prefixes = @($pickByGame[$g]) }
    $cacheDir = Join-Path $retailDir '.vpk-cache'
    foreach ($v in (Get-ChildItem $dir -Recurse -File -Filter '*_dir.vpk' -ErrorAction SilentlyContinue)) {
        if ($isFull) {
            $sets = @(,(Get-VpkEntriesCached $v.FullName $cacheDir))
        }
        elseif ($prefixes.Count) {
            $sets = @($prefixes | ForEach-Object { Get-VpkEntries $v.FullName $_ })
        }
        else { $sets = @() }
        foreach ($set in $sets) {
            foreach ($e in $set) {
                $k = $e.Path.ToLowerInvariant()
                if (-not $index.ContainsKey($k)) { $index[$k] = New-Object System.Collections.ArrayList }
                $index[$k].Add([pscustomobject]@{ Kind='vpk'; Game=$g; Full=$null; Vpk=$e.Vpk; Arch=$e.Arch; Off=$e.Off; Len=$e.Len; Pre=$e.Pre }) | Out-Null
                $n++
            }
        }
    }
    foreach ($f in (Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue)) {
        if ($f.Extension -eq '.vpk') { continue }
        $rel = $f.FullName.Substring($dir.Length+1).Replace('\','/')
        $k = $rel.ToLowerInvariant()
        if (-not $index.ContainsKey($k)) { $index[$k] = New-Object System.Collections.ArrayList }
        $index[$k].Add([pscustomobject]@{ Kind='loose'; Game=$g; Full=$f.FullName; Vpk=$null; Arch=0; Off=0; Len=$f.Length; Pre=$null }) | Out-Null
        $loose++
    }
    Write-Host ("  {0,-6} {1,8:N0} packed, {2,6:N0} loose   {3}" -f $g, $n, $loose, $dir)
}
Write-Host ("  index: {0:N0} retail paths" -f $index.Count)

# ------------------------------- what is already provided above retail ------
# portal_template + core/platform + the leak trees. All of these mount ABOVE
# retail, so retail must never carry a path they already provide.
$provided = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($m in @($modDir, (Join-Path $gameRoot 'core'), (Join-Path $gameRoot 'platform'))) {
    if (-not (Test-Path $m)) { continue }
    foreach ($f in (Get-ChildItem $m -Recurse -File -ErrorAction SilentlyContinue)) {
        [void]$provided.Add($f.FullName.Substring($m.Length+1).Replace('\','/').ToLowerInvariant())
    }
}
$providedModBase = $provided.Count
$top = $provided.Count
foreach ($t in $LeakTrees) {
    $dir = Join-Path $LeakAssets $t
    if (-not (Test-Path $dir)) { continue }
    foreach ($f in (Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue)) {
        [void]$provided.Add($f.FullName.Substring($dir.Length+1).Replace('\','/').ToLowerInvariant())
    }
}
Write-Host ""
Write-Host "== already provided (skipped) ==" -ForegroundColor Cyan
Write-Host ("  portal_template + core + platform {0,8:N0}" -f $providedModBase)
Write-Host ("  leak trees (mounted directly)     {0,8:N0}" -f ($provided.Count - $providedModBase))
Write-Host ("  total                             {0,8:N0}" -f $provided.Count)

# Some leak trees were extracted from a subdirectory of the game they came from, so
# retail indexes the same files under a different prefix. Portal 2 ships its
# tempcontent as portal2\models\portal2_tempcontent\, while the leak holds it as a
# tree of its own. Unmirrored, retail re-ships those files (~4,632, ~900 MB) even
# though the leak already mounts them - and on a long install path the copy trips
# MAX_PATH and aborts the write partway through.
$LeakMirrors = @{ 'portal2_tempcontent' = 'models/portal2_tempcontent' }
$mirrored = 0
foreach ($t in $LeakMirrors.Keys) {
    $dir = Join-Path $LeakAssets $t
    if (-not (Test-Path $dir)) { continue }
    $pre = $LeakMirrors[$t]
    foreach ($f in (Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($dir.Length+1).Replace('\','/').ToLowerInvariant()
        if ($provided.Add("$pre/$rel")) { $mirrored++ }
    }
}
if ($mirrored) { Write-Host ("  mirrored leak subtrees (also skipped) {0,6:N0}" -f $mirrored) }

# ------------------------------------------------------- retail mount -------
$retailPlan = @{}
$retailSize = 0L
foreach ($k in $index.Keys) {
    if ($provided.Contains($k)) { continue }          # the mod/base/leak already supplies it
    if (-not (Test-Asset $k)) { continue }
    if (Test-Blacklisted $k) { continue }
    $src = $index[$k][0]
    if (-not ($FullGames -contains $src.Game)) { continue }   # other games: picks only
    $retailPlan[$k] = $src
    $retailSize += (Get-Size $src)
}

# picks: extra files from the non-full games (by explicit request)
$pickMissing = New-Object System.Collections.ArrayList
if (Test-Path $PickList) {
    foreach ($l in (Get-Content $PickList | Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') })) {
        $t = $l.Trim(); $pin = $null; $p = $t
        if ($t -match '^([A-Za-z0-9]+)\s*:\s*(.+)$') { $pin = $matches[1].ToLowerInvariant(); $p = $matches[2].Trim() }
        $p = $p.ToLowerInvariant()
        if ($pin -eq 'leak') { continue }             # the leak is mounted; nothing to pull
        $cands = if ($p -match '\.[a-z0-9]{1,6}$') { @($p) } else { @($p,"$p.vmt","$p.vtf","$p.mdl","$p.wav","$p.pcf","$p.phy","$p.vvd","$p.vtx") }
        $hit = $false
        foreach ($c in $cands) {
            if (-not $index.ContainsKey($c)) { continue }
            if ($provided.Contains($c) -or $retailPlan.ContainsKey($c)) { $hit = $true; continue }
            foreach ($s in $index[$c]) {
                if ($pin -and $s.Game -ne $pin) { continue }
                $retailPlan[$c] = $s; $retailSize += (Get-Size $s); $hit = $true; break
            }
        }
        if (-not $hit) { [void]$pickMissing.Add($t) }
    }
}

# --- report --------------------------------------------------------------
$byGame = @{}
foreach ($k in $retailPlan.Keys) { $g = $retailPlan[$k].Game; if (-not $byGame.ContainsKey($g)) { $byGame[$g]=0 }; $byGame[$g]++ }
Write-Host ""
Write-Host "== retail (generated; excludes everything already provided) ==" -ForegroundColor Cyan
Write-Host ("  {0:N0} files, {1:N1} MB" -f $retailPlan.Count, ($retailSize/1MB))
$byGame.Keys | Sort-Object { -$byGame[$_] } | ForEach-Object { Write-Host ("      {0,-8} {1,8:N0}" -f $_, $byGame[$_]) }
if ($pickMissing.Count) {
    Write-Host ("  picks unresolved: {0}" -f $pickMissing.Count) -ForegroundColor Yellow
    foreach ($pm in ($pickMissing | Select-Object -First 10)) { Write-Host ("      " + $pm) -ForegroundColor Yellow }
}

if ($DryRun) { Write-Host "`n(dry run - nothing written)"; return }

# --- write ----------------------------------------------------------------
# Entries are processed in chunk order so one file handle is reused for a whole
# chunk and reads move forward - opening/closing per file was the bottleneck.
Write-Host ""
Write-Host "== writing ==" -ForegroundColor Cyan
New-Item -ItemType Directory -Path $retailDir -Force | Out-Null

$order = @($retailPlan.Keys | Sort-Object -Property @{ Expression = {
    $s = $retailPlan[$_]
    if ($s.Kind -eq 'vpk') { '{0}|{1:D12}' -f $s.Vpk, $s.Off } else { 'Z|{0}' -f $_ } } })

$w = 0; $curChunk = $null; $curFs = $null
$buf = New-Object byte[] (1MB)
try {
    foreach ($k in $order) {
        $s = $retailPlan[$k]
        $out = Join-Path $retailDir ($k -replace '/','\')
        $lp  = Get-LongPath $out
        if (Test-Path -LiteralPath $lp) { continue }
        $d  = Split-Path $out -Parent
        $lpd = Get-LongPath $d
        if (-not (Test-Path -LiteralPath $lpd)) { [IO.Directory]::CreateDirectory($lpd) | Out-Null }

        if ($s.Kind -ne 'vpk') {
            Copy-Item -LiteralPath (Get-LongPath $s.Full) -Destination $lp -Force
        } else {
            $chunk = if ($s.Arch -eq 0x7FFF) { $s.Vpk } else { [regex]::Replace($s.Vpk,'_dir\.vpk$',('_{0:D3}.vpk' -f $s.Arch)) }
            if ($curChunk -ne $chunk) {
                if ($curFs) { $curFs.Close() }
                $curFs = [IO.File]::OpenRead((Get-LongPath $chunk)); $curChunk = $chunk
            }
            $outFs = [IO.File]::Create($lp)
            try {
                if ($s.Pre) { $outFs.Write($s.Pre,0,$s.Pre.Length) }
                [void]$curFs.Seek([long]$s.Off,[IO.SeekOrigin]::Begin)
                $left = [long]$s.Len
                while ($left -gt 0) {
                    $want = [int][Math]::Min($buf.Length,$left)
                    $n = $curFs.Read($buf,0,$want); if ($n -le 0) { break }
                    $outFs.Write($buf,0,$n); $left -= $n
                }
            } finally { $outFs.Close() }
        }
        $w++
        if (($w % 2000) -eq 0) { Write-Host ("  retail: {0:N0}" -f $w) }
    }
} finally { if ($curFs) { $curFs.Close() } }
Write-Host ("  retail: wrote {0:N0} files" -f $w)
Write-Host "done."

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

function Get-VpkEntries([string]$vpk) {
    $b = [IO.File]::ReadAllBytes($vpk)
    $res = New-Object System.Collections.ArrayList
    if ($b.Length -lt 12 -or [BitConverter]::ToUInt32($b,0) -ne $sig) { return $res }
    $ver = [BitConverter]::ToUInt32($b,4); $treeSize = [BitConverter]::ToUInt32($b,8)
    $hdr = 12; if ($ver -ge 2) { $hdr = 28 }
    $pos = $hdr; $end = $hdr + $treeSize
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
                $full = if ($pth -eq ' ') { "$nm.$ext" } else { "$pth/$nm.$ext" }
                [void]$res.Add([pscustomobject]@{ Path=$full; Vpk=$vpk; Arch=$arch; Off=$off; Len=$len; Pre=$pd })
            }
        }
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

# ----------------------------------------------------- install index --------
# Only scan what can actually be used: the full games, plus any game named by a
# pick. Indexing CS:GO/L4D2/TF2 wholesale is tens of thousands of entries of
# pure waste otherwise.
$needGames = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($g in $FullGames) { [void]$needGames.Add($g.ToLowerInvariant()) }
if (Test-Path $PickList) {
    foreach ($l in (Get-Content $PickList)) {
        if ($l -match '^\s*([A-Za-z0-9]+)\s*:') { [void]$needGames.Add($matches[1].ToLowerInvariant()) }
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
# two games index the same files.
$gameSubdir = @{ hl2='hl2'; ep2='ep2'; portal='portal'; portal2='portal2'; tf='tf'; l4d2='left4dead2'; csgo='game\csgo' }
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
    foreach ($v in (Get-ChildItem $dir -Recurse -File -Filter '*_dir.vpk' -ErrorAction SilentlyContinue)) {
        foreach ($e in (Get-VpkEntries $v.FullName)) {
            $k = $e.Path.ToLowerInvariant()
            if (-not $index.ContainsKey($k)) { $index[$k] = New-Object System.Collections.ArrayList }
            $index[$k].Add([pscustomobject]@{ Kind='vpk'; Game=$g; Full=$null; Vpk=$e.Vpk; Arch=$e.Arch; Off=$e.Off; Len=$e.Len; Pre=$e.Pre }) | Out-Null
            $n++
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
if ($pickMissing.Count) { Write-Host ("  picks unresolved: {0}" -f $pickMissing.Count) -ForegroundColor Yellow }

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
        if (Test-Path -LiteralPath $out) { continue }
        $d = Split-Path $out -Parent
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }

        if ($s.Kind -ne 'vpk') {
            Copy-Item -LiteralPath $s.Full -Destination $out -Force
        } else {
            $chunk = if ($s.Arch -eq 0x7FFF) { $s.Vpk } else { [regex]::Replace($s.Vpk,'_dir\.vpk$',('_{0:D3}.vpk' -f $s.Arch)) }
            if ($curChunk -ne $chunk) {
                if ($curFs) { $curFs.Close() }
                $curFs = [IO.File]::OpenRead($chunk); $curChunk = $chunk
            }
            $outFs = [IO.File]::Create($out)
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

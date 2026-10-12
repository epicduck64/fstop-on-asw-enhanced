<#
  fix_hammer.ps1 - make Hammer work against this checkout.

  Hammer reads things that live outside git, and they go stale whenever the
  repository moves:

    ..\bin\portal2.fgd             F-STOP's own entity definitions (the leak's
                                   assets\bin\portal2.fgd). Some of its entries
                                   name assets that were never shipped, and one
                                   entry uses a classname the code does not
                                   register - either way the entity is unusable
                                   in Hammer.
    HKCU\...\Valve\Hammer\General  Hammer keeps its autosave folder here, not in
                                   GameConfig.txt.

  (..\bin\GameConfig.txt is written by hammer.bat, which calls this script.)

  Every patch is idempotent, and the first run keeps the original file beside it
  as <name>.bak.

  Usage:  fix_hammer.ps1 [-ModDir <path to game\portal_template>]
#>
param([string]$ModDir)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $ModDir) { $ModDir = Join-Path $repoRoot 'game\portal_template' }
$ModDir = (Resolve-Path -LiteralPath $ModDir).Path
$bin    = Join-Path (Split-Path -Parent $ModDir) 'bin'

$report = New-Object System.Collections.ArrayList

function Backup-Once([string]$path) {
    if (-not (Test-Path -LiteralPath ($path + '.bak'))) { Copy-Item -LiteralPath $path -Destination ($path + '.bak') }
}

# ---------------------------------------------------------------- the FGD ----
$fgd = Join-Path $bin 'portal2.fgd'
if (Test-Path -LiteralPath $fgd) {
    $t = [IO.File]::ReadAllText($fgd)
    $orig = $t

    # prop_tombstone named models/props_fstop/tombstone001.mdl - the F-STOP
    # original, which was never shipped; the class loads the HL2 gravestone.
    $t = $t.Replace('models/props_fstop/tombstone001.mdl', 'models/props_c17/gravestone_cross001a.mdl')

    # the code registers prop_portal_linked_door; the FGD declares a name nothing
    # answers to (in the declaration and in two help strings), so that door cannot
    # be placed and its tooltip points at a class that does not exist.
    $t = $t.Replace('prop_linked_portal_door', 'prop_portal_linked_door')

    # say how the tunnel is used, since the FGD gave it no keyvalues or guidance
    $t = $t.Replace('= prop_portal_tunnel : "A portal tunnel."',
        '= prop_portal_tunnel : "A portal tunnel. Place one flush against a wall: it makes its own far side. failtarget / failtarget_floor / failtarget_ceiling / successtarget name where that far side goes if it cannot attach itself."')

    # npc_android_missile is registered (npc_android_missile.cpp) but was never
    # declared - Hammer shows it as obsolete/unknown (backlog B5).
    if ($t -notmatch '(?m)=\s*npc_android_missile\s') {
        $model = ''
        foreach ($cand in @((Join-Path $ModDir 'models\bot_male\bot_male.mdl'),
                            (Join-Path $repoRoot 'game\p2-2009\portal2_tempcontent\models\bot_male\bot_male.mdl'),
                            (Join-Path $repoRoot 'game\p2-2009\portal2\models\bot_male\bot_male.mdl'))) {
            if (Test-Path -LiteralPath $cand) { $model = ' "models/bot_male/bot_male.mdl" '; break }
        }
        $t += "`r`n@NPCClass base(TalkNPC,Parentname,BaseCapturable) studio($model)= npc_android_missile : `"Aperture Android (Missile)`"`r`n"
    }

    if ($t -ne $orig) {
        Backup-Once $fgd
        [IO.File]::WriteAllText($fgd, $t)
        [void]$report.Add('portal2.fgd patched')
    }
} else {
    [void]$report.Add('portal2.fgd not found - copy F-STOP''s from the leak''s assets\bin\')
}

# ------------------------------------------------------------ autosave dir ----
$auto = Join-Path $bin 'HammerAutosave'
if (-not (Test-Path -LiteralPath $auto)) { New-Item -ItemType Directory -Path $auto -Force | Out-Null }
$key = 'HKCU:\Software\Valve\Hammer\General'
if (Test-Path $key) {
    $cur = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).'Autosave Dir'
    if (-not $cur -or -not (Test-Path -LiteralPath ([string]$cur).Trim())) {
        Set-ItemProperty -Path $key -Name 'Autosave Dir' -Value ($auto + '\')
        [void]$report.Add('autosave dir -> ' + $auto + '\')
    }
}

if ($report.Count) { $report | ForEach-Object { Write-Host ('fix_hammer: ' + $_) } }

# generate_assets.ps1 - restore the project's asset overrides.
#
# Counterpart to generate_diffs.ps1: copies everything under diffs\ back into
# portal_template. diffs\ holds plain binary files, so this is a straight copy.
#
# tools/generate_assets.bat [-Force]

[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$ModPath  = 'game\portal_template',
    [string]$DiffDir  = 'diffs',
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$modDir   = Join-Path $RepoRoot $ModPath
$diffRoot = Join-Path $RepoRoot $DiffDir
if (-not (Test-Path $diffRoot)) { throw "No diffs\ at $diffRoot - run tools/generate_diffs.bat first" }

$n = 0; $skipped = 0
foreach ($f in (Get-ChildItem $diffRoot -Recurse -File -ErrorAction SilentlyContinue)) {
    $rel = $f.FullName.Substring($diffRoot.Length+1)
    if ($rel -eq 'manifest.txt') { continue }
    $out = Join-Path $modDir $rel
    if (-not $Force -and (Test-Path -LiteralPath $out)) { $skipped++; continue }
    $d = Split-Path $out -Parent
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Copy-Item -LiteralPath $f.FullName -Destination $out -Force
    $n++
}
Write-Host ("restored {0:N0} overrides into {1} (skipped {2:N0} existing)" -f $n, $ModPath, $skipped)

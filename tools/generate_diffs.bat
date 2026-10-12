@echo off
rem generate_diffs.bat - express portal_template as patches against the leak.
rem
rem The repository ships patches, not assets. Writes diffs\ (manifest.tsv plus one
rem patch per changed file). Applying them with generate_assets.bat rebuilds
rem portal_template exactly.
rem
rem Prerequisites: the leak placed at game\p2-2009 (or pass -LeakAssets <path>).
rem
rem   tools\generate_diffs.bat            write the patches
rem   tools\generate_diffs.bat -DryRun    report only
setlocal EnableExtensions
set "REPO=%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0generate_diffs.ps1" -RepoRoot "%REPO%" %*
exit /b %errorlevel%

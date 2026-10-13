@echo off
rem generate_assets.bat - rebuild portal_template from the leak + diffs\.
rem
rem Counterpart to generate_diffs.bat. Sparse patches are applied on top of the
rem leak's copy; full patches carry their own content.
rem
rem Prerequisites: the leak at game\p2-2009 (or -LeakAssets <path>), and
rem diffs\ produced by generate_diffs.bat.
rem
rem   tools\generate_assets.bat           rebuild missing/changed files
rem   tools\generate_assets.bat -Force    overwrite files that already exist
setlocal EnableExtensions
set "REPO=%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0generate_assets.ps1" -RepoRoot "%REPO%" %*
exit /b %errorlevel%

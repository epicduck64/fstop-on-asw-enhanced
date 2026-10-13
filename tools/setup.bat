@echo off
rem setup.bat - one-shot setup for a fresh checkout.
rem
rem   1. rebuild portal_template from the leak + diffs\   (generate_assets)
rem   2. unpack the retail mount                           (build_mounts)
rem
rem Prerequisites:
rem   * the retail games installed via Steam - build_mounts locates them itself,
rem     wherever they live, and
rem   * the 2009 leak content under game\p2-2009, which is mounted directly and
rem     never copied (pass -LeakAssets <path> to point somewhere else).
rem
rem   tools\setup.bat             run both steps
rem   (build_mounts, clean_mod and generate_diffs take -DryRun; generate_assets
rem    does not, so this script cannot be dry-run as a whole)
setlocal EnableExtensions
set "REPO=%~dp0.."
echo === 1/2 rebuilding portal_template from diffs ===
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0generate_assets.ps1" -RepoRoot "%REPO%" %*
if errorlevel 1 ( echo generate_assets failed. & exit /b 1 )
echo === 2/2 building mounts ===
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_mounts.ps1" -RepoRoot "%REPO%" %*
if errorlevel 1 ( echo build_mounts failed. & exit /b 1 )
echo === setup complete ===
exit /b 0

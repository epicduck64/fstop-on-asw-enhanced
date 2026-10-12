@echo off
rem clean_mod.bat - drop redundant files from portal_template.
rem
rem portal_template mounts first, so anything in it that is byte-identical to what
rem the leak or retail already serve is pointless. Removes those; keeps only the
rem files that genuinely differ.
rem
rem   tools\clean_mod.bat            remove
rem   tools\clean_mod.bat -DryRun    list what would be removed
setlocal EnableExtensions
set "REPO=%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0clean_mod.ps1" -RepoRoot "%REPO%" %*
exit /b %errorlevel%

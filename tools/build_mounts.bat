@echo off
rem build_mounts.bat - build the retail mount.
rem
rem   game\retail        retail assets (HL2 + Portal + Portal 2 full, plus picks)
rem
rem Nothing is ever removed: portal_template is the source of truth for the
rem project's own work, and the generated mount is given no path that
rem portal_template, core, platform or the leak already provide, so the mod can
rem never be shadowed by a generated copy.
rem
rem Prerequisites:
rem   1. the retail games installed via Steam - located automatically, including
rem      across multiple libraries on different drives, and
rem   2. the 2009 leak content under game\p2-2009, mounted directly and never
rem      copied (pass -LeakAssets <path> to point somewhere else).
rem
rem Usage:
rem   tools\build_mounts.bat                 build the mount
rem   tools\build_mounts.bat -DryRun         report only, write nothing
setlocal EnableExtensions
set "REPO=%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_mounts.ps1" -RepoRoot "%REPO%" %*
exit /b %errorlevel%

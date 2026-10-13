@echo off
rem ============================================================================
rem  compile.bat [mapname] - compile a map without Hammer.
rem
rem  Runs VBSP / VVIS / VRAD with the game folder passed explicitly, which is
rem  what Hammer's own compile step is failing to do here. Defaults to "devtest".
rem
rem  Mirrors the shape of the project's own compile_vmf.bat, but targets the mod
rem  as it now lives, using the SDK's compiler set.
rem ============================================================================
setlocal
set "MOD=%~dp0."
set "BIN=%~dp0..\bin"
set "MAP=%~1"
if "%MAP%"=="" set "MAP=devtest"

if not exist "%MOD%\maps\%MAP%.vmf" (
	echo ERROR: "%MOD%\maps\%MAP%.vmf" not found - save the map first.
	pause
	exit /b 1
)

pushd "%BIN%"
echo ==== VBSP ====
vbsp.exe -game "%MOD%" "%MOD%\maps\%MAP%.vmf"
if errorlevel 1 goto :failed

echo ==== VVIS ====
vvis.exe -game "%MOD%" "%MOD%\maps\%MAP%.bsp"
if errorlevel 1 goto :failed

echo ==== VRAD ====
vrad.exe -game "%MOD%" "%MOD%\maps\%MAP%.bsp"
if errorlevel 1 goto :failed
popd

echo.
echo Compiled %MAP% - run it with: run_map.bat %MAP%
pause
exit /b 0

:failed
popd
echo.
echo COMPILE FAILED - see the output above.
pause
exit /b 1

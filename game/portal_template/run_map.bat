@echo off
rem ============================================================================
rem  run_map.bat [mapname] - launch the mod straight into a map
rem
rem  Defaults to "devtest" if no map is given. Sits next to run_mod.bat.
rem  Handy after an F9 compile in Hammer, since Hammer's own "run the game"
rem  step doesn't always fire here.
rem
rem  Also writes game\portal_template\console.log (-condebug), so compile-time
rem  and spawn errors are captured.
rem
rem  mat_hdr_level 3 puts the renderer in float HDR. The camera's depth of field
rem  is gated on it (IsDepthOfFieldEnabled requires HDR_TYPE_FLOAT in
rem  viewpostprocess.cpp), so without this the viewfinder shows no focus effect
rem  at all. Level 3 is the float level on this engine; 2 stays on integer HDR.
rem ============================================================================
setlocal
set "MAP=%~1"
if "%MAP%"=="" set "MAP=devtest"

if not exist "..\swarm.exe" (
	echo ERROR: swarm.exe not found one level up - run this from the mod folder.
	pause
	exit /b 1
)
if not exist "maps\%MAP%.bsp" (
	echo WARNING: maps\%MAP%.bsp not found - compile it in Hammer ^(F9^) first.
	echo.
)

@"../swarm.exe" -sw -w 1280 -h 720 -dev -condebug -override_vpk -allowdebug +mat_hdr_level 3 -game portal_template +map %MAP%
endlocal

@echo off
rem ============================================================================
rem  hammer.bat - launch Hammer pointed at this mod (Aperture / F-STOP)
rem
rem  Writes ..\bin\GameConfig.txt first - a single "Aperture (F-STOP)" entry
rem  whose GameDir, FGD, compile tools, map dirs and GameExe are derived from
rem  this script's own location, so they always match the tree Hammer is being
rem  launched from. The previous config is kept as GameConfig.txt.bak.
rem
rem  Re-run this after moving the repository, or use:
rem
rem    hammer.bat                  write the config, then launch Hammer
rem    hammer.bat -writeconfig     write the config only, no launch
rem
rem  Then compile with F9 in Hammer; the BSP lands in ..\..\portal_template\maps.
rem ============================================================================
setlocal EnableExtensions

set "MODDIR=%~dp0"
if "%MODDIR:~-1%"=="\" set "MODDIR=%MODDIR:~0,-1%"
for %%I in ("%MODDIR%\..\bin") do set "BINDIR=%%~fI"
for %%I in ("%MODDIR%\..")     do set "GAMEDIR=%%~fI"
set "CFG=%BINDIR%\GameConfig.txt"

if not exist "%BINDIR%\hammer.exe" (
	echo ERROR: hammer.exe not found in "%BINDIR%".
	echo        This needs an install that has the SDK tools in the folder above the mod.
	pause
	exit /b 1
)

rem keep the first config we ever see, so a regeneration is always reversible
if exist "%CFG%" if not exist "%CFG%.bak" copy /Y "%CFG%" "%CFG%.bak" >nul

rem Hammer lists prefabs from here and complains when the folder is absent
if not exist "%BINDIR%\Prefabs" mkdir "%BINDIR%\Prefabs"

(
	echo "Configs"
	echo {
	echo 	"Games"
	echo 	{
	echo 		"Aperture (F-STOP)"
	echo 		{
	echo 			"GameDir"		"%MODDIR%"
	echo 			"Hammer"
	echo 			{
	echo 				"GameData0"		"%BINDIR%\portal2.fgd"
	echo 				"TextureFormat"		"5"
	echo 				"MapFormat"		"4"
	echo 				"DefaultTextureScale"	"0.250000"
	echo 				"DefaultLightmapScale"	"16"
	echo 				"GameExe"		"%GAMEDIR%\swarm.exe"
	echo 				"GameExeDir"		"%GAMEDIR%"
	echo 				"MapDir"		"%MODDIR%\maps"
	echo 				"BSPDir"		"%MODDIR%\maps"
	echo 				"PrefabDir"		"%BINDIR%\Prefabs"
	echo 				"BSP"			"%BINDIR%\vbsp.exe"
	echo 				"Vis"			"%BINDIR%\vvis.exe"
	echo 				"Light"			"%BINDIR%\vrad.exe"
	echo 				"DefaultSolidEntity"	"func_detail"
	echo 				"DefaultPointEntity"	"info_player_start"
	echo 				"CordonTexture"		"tools/toolsskybox"
	echo 				"MaterialExcludeCount"	"0"
	echo 			}
	echo 		}
	echo 	}
	echo 	"SDKVersion"		"5"
	echo }
) > "%CFG%"

rem F-STOP's own FGD (the leak's assets\bin\portal2.fgd, which is what lives in
rem ..\bin) declares prop_tombstone's model as models/props_fstop/tombstone001.mdl
rem - the original that was never shipped - so Hammer draws its error model.
rem Repoint it at the model the class actually loads; the leak's hl2 tree supplies
rem that model's .vtx and .phy. Kept as portal2.fgd.bak, and idempotent.
set "FGD=%BINDIR%\portal2.fgd"

rem Hammer keeps its autosave folder in the registry (HKCU\Software\Valve\Hammer\
rem General\Autosave Dir) rather than in GameConfig.txt, so it goes stale the same
rem way once the tree moves - that is the "autosave" warning. Repoint it whenever
rem the folder it names is gone.
rem The FGD and the registry autosave path are repaired by tools\fix_hammer.ps1,
rem which is idempotent and keeps *.bak beside whatever it edits.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\tools\fix_hammer.ps1" -ModDir "%MODDIR%"

if /i "%~1"=="-writeconfig" (
	echo Wrote "%CFG%"
	endlocal
	exit /b 0
)

if not exist "%BINDIR%\portal2.fgd" (
	echo WARNING: portal2.fgd not found in "%BINDIR%" - the Aperture entities
	echo          such as prop_tombstone / prop_building / weapon_camera / npc_android
	echo          will not appear. It is F-STOP's own FGD: copy it from the leak's
	echo          assets\bin\portal2.fgd.
	echo.
)

rem Hammer resolves its DLLs relative to its own directory, so launch from there
cd /d "%BINDIR%"
start "Hammer - Aperture" hammer.exe -nop4 -threads 4 -game "%MODDIR%"

endlocal

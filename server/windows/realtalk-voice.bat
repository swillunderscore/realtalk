@echo off
rem ==========================================================================
rem  RealTalk voice server (Windows), in THIS window, until it is closed.
rem
rem  realtalk-launch.bat starts this for you, minimized, and stops it when the
rem  game exits. Run it by hand when the game is started some other way - e.g.
rem  from GOG Galaxy or the Epic launcher, which can only append arguments and
rem  so can't wrap the game in realtalk-launch.bat.
rem
rem  Output goes to logs\realtalk-tts.log. A startup crash used to vanish with
rem  the minimized window; now it stays in the log.
rem ==========================================================================

setlocal
set DIR=%~dp0
set GAME=%DIR%..\..
set PY=%DIR%python\python.exe
set LOG=%DIR%logs\realtalk-tts.log

if not exist "%PY%" (
    echo [RealTalk] Voice service not set up yet - run realtalk-launch.bat once first.
    exit /b 1
)
if not exist "%DIR%logs" mkdir "%DIR%logs"

rem XTTS-v2 weights: Coqui Public Model License (non-commercial); the
rem library downloads them on first run and would ask to agree in a
rem console nobody sees - accepted here, disclosed in the README.
set COQUI_TOS_AGREED=1
rem the log is read while the server runs - don't let python buffer it
set PYTHONUNBUFFERED=1

echo [RealTalk] Voice server running - close this window to stop it.
echo [RealTalk] Log: %LOG%
"%PY%" "%DIR%realtalk-tts.py" ^
    --slots "%GAME%\r6\audioware\RealTalk\slots" ^
    --voices "%DIR%voices" ^
    --port 8082 --device cpu ^
    --game-dir "%GAME%" ^
    --wolvenkit "%DIR%tools\WolvenKit.CLI.exe" ^
    --vgmstream "%DIR%tools\vgmstream-cli.exe" > "%LOG%" 2>&1
set RC=%ERRORLEVEL%
if not "%RC%"=="0" echo [RealTalk] Voice server stopped (exit %RC%) - see %LOG%
exit /b %RC%

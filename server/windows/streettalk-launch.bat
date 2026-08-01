@echo off
rem ==========================================================================
rem  StreetTalk launcher (Windows). The ONLY thing a user ever sets up:
rem
rem    Steam > Cyberpunk 2077 > Properties > Launch Options:
rem      "C:\...\Cyberpunk 2077\tools\StreetTalk\streettalk-launch.bat" %command% -no-tls
rem
rem  (-no-tls is only needed for local AI models; cloud users still add this
rem   line, just without caring about that flag.)
rem
rem  From then on the Play button does everything: first run bootstraps a
rem  private Python and the voice stack (visible, ordinary tools - nothing
rem  packaged or hidden; read bootstrap.py, it is short), every run starts
rem  the voice service minimized and stops it when the game exits.
rem
rem  This folder is meant to live at <game>\tools\StreetTalk\.
rem ==========================================================================

setlocal
set DIR=%~dp0
set GAME=%DIR%..\..
set PYDIR=%DIR%python
set PY=%PYDIR%\python.exe

rem ---- first run: bootstrap (python + deps + tools), all visible code ----
if not exist "%PY%" (
    echo [StreetTalk] First run - setting up the voice service...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%bootstrap.ps1" || (
        echo [StreetTalk] Bootstrap failed - the game will start without voice.
        goto :game
    )
)

rem ---- start the voice service if it is not already running ----
tasklist /FI "WINDOWTITLE eq StreetTalkVoice*" 2>NUL | find /I "python" >NUL
if errorlevel 1 (
    rem Kill any voice server left over from a previous session - a survivor
    rem holds the port and serves stale code (see linux launcher note).
    taskkill /F /FI "WINDOWTITLE eq StreetTalkVoice*" >nul 2>&1

    rem XTTS-v2 weights: Coqui Public Model License (non-commercial); the
    rem library downloads them on first run and would ask to agree in a
    rem console nobody sees - accepted here, disclosed in the README.
    set COQUI_TOS_AGREED=1
    start "StreetTalkVoice" /MIN "%PY%" "%DIR%streettalk-tts.py" ^
        --slots "%GAME%\r6\audioware\StreetTalk\slots" ^
        --voices "%DIR%voices" ^
        --port 8082 --device cpu ^
        --game-dir "%GAME%" ^
        --wolvenkit "%DIR%tools\WolvenKit.CLI.exe" ^
        --vgmstream "%DIR%tools\vgmstream-cli.exe"
)

:game
%*
set RC=%ERRORLEVEL%

rem ---- game exited: stop the voice service we started ----
taskkill /FI "WINDOWTITLE eq StreetTalkVoice*" /T /F >NUL 2>&1
exit /b %RC%

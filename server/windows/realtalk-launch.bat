@echo off
rem ==========================================================================
rem  RealTalk launcher (Windows). The ONLY thing a user ever sets up:
rem
rem    Steam > Cyberpunk 2077 > Properties > Launch Options:
rem      "C:\...\Cyberpunk 2077\tools\RealTalk\realtalk-launch.bat" %command% -no-tls
rem
rem  (-no-tls is only needed for local AI models; cloud users still add this
rem   line, just without caring about that flag.)
rem
rem  GOG Galaxy / Epic can only APPEND arguments, so they can't wrap the game
rem  in this file. Run it yourself instead (a desktop shortcut works) - with
rem  no arguments it starts <game>\bin\x64\Cyberpunk2077.exe -no-tls. Or launch
rem  the game from the client and run realtalk-voice.bat alongside it.
rem
rem  From then on the Play button does everything: first run bootstraps a
rem  private Python and the voice stack (visible, ordinary tools - nothing
rem  packaged or hidden; read bootstrap.py, it is short), every run starts
rem  the voice service minimized and stops it when the game exits.
rem
rem  This folder is meant to live at <game>\tools\RealTalk\.
rem ==========================================================================

setlocal
set DIR=%~dp0
set GAME=%DIR%..\..
set PYDIR=%DIR%python
set PY=%PYDIR%\python.exe

rem ---- first run: bootstrap (python + deps + tools), all visible code ----
rem Also re-run it for installs made before the bootstrap fetched FFmpeg:
rem torchcodec is there but its FFmpeg dlls are not, so every line fails.
set NEEDBOOT=
set TC=%PYDIR%\Lib\site-packages\torchcodec
if not exist "%PY%" set NEEDBOOT=1
if exist "%TC%\" if not exist "%TC%\avcodec-*.dll" set NEEDBOOT=1
if defined NEEDBOOT (
    echo [RealTalk] First run - setting up the voice service...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%bootstrap.ps1" || (
        echo [RealTalk] Bootstrap failed - the game will start without voice.
        goto :game
    )
)

rem ---- start the voice service if it is not already running ----
rem "Running" = something is listening on its port. That also leaves alone a
rem server started by hand with realtalk-voice.bat.
netstat -ano -p TCP | find ":8082 " | find "LISTENING" >NUL
if not errorlevel 1 goto :game

rem Kill any voice server left over from a previous session - a survivor
rem holds the port and serves stale code (see linux launcher note).
taskkill /F /T /FI "WINDOWTITLE eq RealTalkVoice*" >nul 2>&1

rem Minimized; output goes to logs\realtalk-tts.log (realtalk-voice.bat).
rem Doubled quotes: cmd /c strips one pair, and "Program Files (x86)" would
rem otherwise break the path at the parenthesis. That leaves the path
rem unquoted to this script's parser, so this line must NOT be inside an
rem if ( ... ) block - the ")" of "(x86)" would close it.
start "RealTalkVoice" /MIN cmd /c ""%DIR%realtalk-voice.bat""

:game
rem No arguments = not started from Steam: start the game ourselves.
if not "%~1"=="" goto :args
"%GAME%\bin\x64\Cyberpunk2077.exe" -no-tls
goto :played
:args
%*
:played
set RC=%ERRORLEVEL%

rem ---- game exited: stop the voice service we started ----
taskkill /FI "WINDOWTITLE eq RealTalkVoice*" /T /F >NUL 2>&1
exit /b %RC%

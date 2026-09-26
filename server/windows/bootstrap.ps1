# RealTalk first-run bootstrap (Windows). Plain script on purpose - read
# every line. It fetches ORDINARY, well-known tools into this folder and
# nothing else on the system is touched:
#
#   python\        the official python.org embeddable runtime
#   tools\         WolvenKit CLI (GitHub) + vgmstream (GitHub) - used to
#                  extract characters' voice lines from YOUR OWN archives
#   Lib\...        pip packages: PyTorch (CPU wheels) + coqui-tts, plus the
#                  FFmpeg dlls (GitHub, BtbN LGPL build) torchcodec needs
#
# Runs once; after this the launcher starts instantly. Everything downloaded
# is a released build of an open project, fetched over https from its
# official source, versions pinned below.

$ErrorActionPreference = "Stop"
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path

$PY_URL  = "https://www.python.org/ftp/python/3.11.9/python-3.11.9-embed-amd64.zip"
$PIP_URL = "https://bootstrap.pypa.io/get-pip.py"
$WKIT_URL = "https://github.com/WolvenKit/WolvenKit/releases/download/8.19.0/WolvenKit.Console-8.19.0.zip"
$VGM_URL = "https://github.com/vgmstream/vgmstream/releases/download/r2117/vgmstream-win64.zip"
# LGPL shared build; torchcodec loads its dlls (see the FFmpeg step below)
$FFMPEG_URL = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n9.0-latest-win64-lgpl-shared-9.0.zip"

function Fetch($url, $out) {
    Write-Host "[bootstrap] fetching $url"
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
}

# ---- python (embeddable, private to this folder) ----
$pydir = Join-Path $dir "python"
if (-not (Test-Path (Join-Path $pydir "python.exe"))) {
    $zip = Join-Path $dir "python.zip"
    Fetch $PY_URL $zip
    Expand-Archive $zip -DestinationPath $pydir -Force
    Remove-Item $zip
    # the embeddable build ships with `import site` disabled; pip needs it.
    # Its ._pth also stops the script's own folder (one level up, where
    # realtalk-tts.py and voice_forge.py live) from landing on sys.path -
    # add it explicitly.
    $pth = Get-ChildItem $pydir -Filter "python*._pth" | Select-Object -First 1
    $lines = @((Get-Content $pth.FullName) -replace "#import site", "import site")
    if ($lines -notcontains "..") { $lines += ".." }
    $lines | Set-Content $pth.FullName
    $getpip = Join-Path $dir "get-pip.py"
    Fetch $PIP_URL $getpip
    & (Join-Path $pydir "python.exe") $getpip --no-warn-script-location
    Remove-Item $getpip
}
$py = Join-Path $pydir "python.exe"

# ---- the voice stack (CPU wheels: works on every machine, no GPU needed) ----
& $py -m pip install --no-warn-script-location torch torchaudio torchcodec `
    --index-url https://download.pytorch.org/whl/cpu
& $py -m pip install --no-warn-script-location coqui-tts "transformers<5"

# ---- FFmpeg for torchcodec ----
# Current torchaudio reads audio through torchcodec, which needs FFmpeg's
# SHARED dlls (major 4-9) and does not bring them. Without them every /speak
# fails with "Could not load libtorchcodec". Windows resolves a dll's
# dependencies from that dll's own folder, so dropping them next to
# torchcodec's is enough - no PATH change, nothing system-wide.
$tcdir = Join-Path $pydir "Lib\site-packages\torchcodec"
if ((Test-Path $tcdir) -and -not (Get-ChildItem $tcdir -Filter "avcodec-*.dll")) {
    $zip = Join-Path $dir "ffmpeg.zip"
    $tmp = Join-Path $dir "ffmpeg-tmp"
    Fetch $FFMPEG_URL $zip
    Expand-Archive $zip -DestinationPath $tmp -Force
    Get-ChildItem $tmp -Recurse -Filter "*.dll" | Copy-Item -Destination $tcdir -Force
    Remove-Item $zip
    Remove-Item $tmp -Recurse -Force
}

# ---- extraction tools, for forging voices from the player's own archives ----
$tools = Join-Path $dir "tools"
New-Item -ItemType Directory -Force -Path $tools | Out-Null
if (-not (Test-Path (Join-Path $tools "WolvenKit.CLI.exe"))) {
    $zip = Join-Path $dir "wkit.zip"
    Fetch $WKIT_URL $zip
    Expand-Archive $zip -DestinationPath $tools -Force
    Remove-Item $zip
}
if (-not (Test-Path (Join-Path $tools "vgmstream-cli.exe"))) {
    $zip = Join-Path $dir "vgm.zip"
    Fetch $VGM_URL $zip
    Expand-Archive $zip -DestinationPath $tools -Force
    Remove-Item $zip
}

Write-Host "[bootstrap] done - the voice service is ready."

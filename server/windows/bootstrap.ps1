# RealTalk first-run bootstrap (Windows). Plain script on purpose - read
# every line. It fetches ORDINARY, well-known tools into this folder and
# nothing else on the system is touched:
#
#   python\        the official python.org embeddable runtime
#   tools\         WolvenKit CLI (GitHub) + vgmstream (GitHub) - used to
#                  extract characters' voice lines from YOUR OWN archives
#   Lib\...        pip packages: PyTorch (CPU wheels) + coqui-tts
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
    # the embeddable build ships with `import site` disabled; pip needs it
    $pth = Get-ChildItem $pydir -Filter "python*._pth" | Select-Object -First 1
    (Get-Content $pth.FullName) -replace "#import site", "import site" |
        Set-Content $pth.FullName
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

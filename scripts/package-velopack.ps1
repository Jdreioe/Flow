$ErrorActionPreference = 'Stop'

if (-not $env:VERSION) { throw 'VERSION environment variable is required' }
if ($env:VERSION -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must be major.minor.patch, got '$env:VERSION'"
}

$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'target\release\flow-windows.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    throw "Built exe not found at $exe"
}

$dist = Join-Path $root 'dist'
$staging = Join-Path $dist 'staging'
Remove-Item -Recurse -Force $dist -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $staging | Out-Null

Copy-Item -LiteralPath $exe -Destination (Join-Path $staging 'flow-windows.exe')

$windeployqt = $null
foreach ($candidate in @(
    (Join-Path $env:QT_ROOT_DIR 'bin\windeployqt.exe'),
    (Get-ChildItem 'C:\Qt\6.*\msvc*_64\bin\windeployqt.exe' -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName))) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
        $windeployqt = $candidate
        break
    }
}
if (-not $windeployqt) { throw 'windeployqt not found; set QT_ROOT_DIR or install Qt 6 MSVC' }

$stagedExe = Join-Path $staging 'flow-windows.exe'
& $windeployqt --release --no-translations --dir $staging $stagedExe
if ($LASTEXITCODE -ne 0) { throw 'windeployqt failed' }

$crtDir = $null
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path -LiteralPath $vswhere) {
    $vsRoot = & $vswhere -latest -products * -property installationPath
    if ($vsRoot) {
        $redist = Get-ChildItem (Join-Path $vsRoot 'VC\Redist\MSVC') -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'x64\Microsoft.VC143.CRT') } |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($redist) { $crtDir = Join-Path $redist.FullName 'x64\Microsoft.VC143.CRT' }
    }
}
if ($crtDir) {
    Copy-Item (Join-Path $crtDir '*.dll') $staging
} else {
    Write-Warning 'VC++ CRT DLLs not found; target machines need the VC++ 2015-2022 redistributable'
}

$vpk = Join-Path "$env:USERPROFILE\.dotnet\tools" 'vpk.exe'
if (-not (Test-Path -LiteralPath $vpk)) { $vpk = 'vpk' }

$packArgs = @(
    'pack',
    '--packId', 'Flow',
    '--packVersion', $env:VERSION,
    '--packDir', $staging,
    '--mainExe', 'flow-windows.exe',
    '--outputDir', (Join-Path $dist 'Releases')
)
# Optional code signing: set VPK_SIGNPARAMS to signtool arguments, e.g.
#   VPK_SIGNPARAMS: /a /f cert.pfx /p <password> /fd SHA256 /tr <timestamp-url> /td SHA256
if ($env:VPK_SIGNPARAMS) {
    $packArgs += @('--signParams', $env:VPK_SIGNPARAMS)
}

& $vpk @packArgs
if ($LASTEXITCODE -ne 0) { throw 'vpk pack failed' }

Write-Host "Packaged Velopack release under $(Join-Path $dist 'Releases')"

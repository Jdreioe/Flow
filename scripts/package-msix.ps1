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

$tag = "v$($env:VERSION)"
$dist = Join-Path $root 'dist'
$staging = Join-Path $dist 'staging'
Remove-Item -Recurse -Force $dist -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $staging | Out-Null

Copy-Item -LiteralPath $exe -Destination (Join-Path $staging 'flow-windows.exe')

$manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
         xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
         xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities">
  <Identity Name="jdreioe.Flow" Version="$($env:VERSION).0" Publisher="CN=Flow RC" />
  <Properties>
    <DisplayName>Flow</DisplayName>
    <PublisherDisplayName>jdreioe</PublisherDisplayName>
    <Logo>Assets\StoreLogo.png</Logo>
  </Properties>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.19041.0" MaxVersionTested="10.0.26100.0" />
  </Dependencies>
  <Resources>
    <Resource Language="en-us" />
  </Resources>
  <Applications>
    <Application Id="Flow" Executable="flow-windows.exe" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements
        DisplayName="Flow"
        Description="Selected-text reader with sentence-level language routing"
        BackgroundColor="#355275"
        Square150x150Logo="Assets\Square150x150Logo.png"
        Square44x44Logo="Assets\Square44x44Logo.png" />
    </Application>
  </Applications>
  <Capabilities>
    <rescap:Capability Name="runFullTrust" />
  </Capabilities>
</Package>
"@
Set-Content -LiteralPath (Join-Path $staging 'AppxManifest.xml') -Value $manifest -Encoding utf8

Add-Type -AssemblyName System.Drawing
function New-Placeholder([string]$path, [int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(0x35, 0x52, 0x75))
    $font = New-Object System.Drawing.Font 'Segoe UI', ($size * 0.4), ([System.Drawing.FontStyle]::Bold)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString('F', $font, [System.Drawing.Brushes]::White,
        (New-Object System.Drawing.RectangleF 0, 0, $size, $size), $fmt)
    $g.Dispose()
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}
$assets = Join-Path $staging 'Assets'
New-Item -ItemType Directory -Force $assets | Out-Null
New-Placeholder (Join-Path $assets 'StoreLogo.png') 50
New-Placeholder (Join-Path $assets 'Square44x44Logo.png') 44
New-Placeholder (Join-Path $assets 'Square150x150Logo.png') 150

$sdkBin = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Directory |
    Where-Object { $_.Name -match '^10\.' } |
    Sort-Object { [version]$_.Name } -Descending |
    Select-Object -First 1
if (-not $sdkBin) { throw 'Windows SDK bin directory not found' }
$makeappx = Join-Path $sdkBin.FullName 'x64\makeappx.exe'
$signtool = Join-Path $sdkBin.FullName 'x64\signtool.exe'
foreach ($tool in @($makeappx, $signtool)) {
    if (-not (Test-Path -LiteralPath $tool)) { throw "Tool not found: $tool" }
}

$msix = Join-Path $dist "Flow-$tag.msix"
& $makeappx pack /o /d $staging /p $msix
if ($LASTEXITCODE -ne 0) { throw 'makeappx pack failed' }

$pfxPassword = ConvertTo-SecureString -String 'flow-rc' -AsPlainText -Force
$cert = New-SelfSignedCertificate `
    -Type Custom `
    -Subject 'CN=Flow RC' `
    -KeyUsage DigitalSignature `
    -FriendlyName 'Flow RC packaging' `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
$pfx = Join-Path ([System.IO.Path]::GetTempPath()) 'flow-rc.pfx'
Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $pfxPassword | Out-Null

& $signtool sign /fd SHA256 /a /f $pfx /p 'flow-rc' $msix
if ($LASTEXITCODE -ne 0) { throw 'signtool sign failed' }

Export-Certificate -Cert $cert -FilePath (Join-Path $dist 'Flow-RC.cer') | Out-Null
Remove-Item -LiteralPath $pfx -Force

Write-Host "Packaged $msix"

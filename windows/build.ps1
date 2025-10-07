<# build.ps1
   Builds & signs the RNDIS driver package and the Inno Setup installer.
   Requires: Windows SDK (signtool), Inno Setup 6 (ISCC.exe), Windows Driver Kit (Inf2cat.exe)
#>

param(
  [string]$InfName       = "raspberrypi-rndis.inf",
  [string]$CatName       = "raspberrypi-rndis.cat",
  [string]$IssFile       = "setup.iss",
  [string]$OutputBase    = "rpi-usb-gadget-driver-setup",   # matches OutputBaseFilename in .iss
  [string]$CertSubject   = "Raspberry Pi Limited",             # OR set $CertThumbprint below
  [string]$CertThumbprint = "",                             # takes precedence if provided
  [string]$TimestampUrl  = "http://timestamp.digicert.com",
  [switch]$SignOutputExe = $true                            # extra sign step for the installer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Find-SignTool {
  $candidates = @()
  if ($env:SIGNTOOL) { $candidates += $env:SIGNTOOL }
  
  # Search for Windows SDK installations
  $sdkBase = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
  if (Test-Path $sdkBase) {
    # Find the latest version directory
    $versions = Get-ChildItem $sdkBase -Directory | Where-Object { $_.Name -match '^\d+\.\d+' } | Sort-Object Name -Descending
    foreach ($ver in $versions) {
      $candidates += Join-Path $ver.FullName "x64\signtool.exe"
      $candidates += Join-Path $ver.FullName "x86\signtool.exe"
      $candidates += Join-Path $ver.FullName "arm64\signtool.exe"
    }
  }
  
  # Also check if it's in PATH
  $inPath = Get-Command "signtool.exe" -ErrorAction SilentlyContinue
  if ($inPath) { $candidates += $inPath.Source }
  
  foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path }
  }
  throw "signtool.exe not found. Install Windows SDK or set `$env:SIGNTOOL to its path."
}

function Find-Inf2cat {
  $candidates = @()
  if ($env:INF2CAT) { $candidates += $env:INF2CAT }
  
  # Search for WDK installations
  $wdkBase = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
  if (Test-Path $wdkBase) {
    # Find the latest version directory
    $versions = Get-ChildItem $wdkBase -Directory | Where-Object { $_.Name -match '^\d+\.\d+' } | Sort-Object Name -Descending
    foreach ($ver in $versions) {
      $candidates += Join-Path $ver.FullName "x64\Inf2cat.exe"
      $candidates += Join-Path $ver.FullName "x86\Inf2cat.exe"
      $candidates += Join-Path $ver.FullName "arm64\Inf2cat.exe"
    }
  }
  
  # Also check if it's in PATH
  $inPath = Get-Command "Inf2cat.exe" -ErrorAction SilentlyContinue
  if ($inPath) { $candidates += $inPath.Source }
  
  foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path }
  }
  throw "Inf2cat.exe not found. Install Windows Driver Kit (WDK) or set `$env:INF2CAT to its path."
}

function Find-ISCC {
  $candidates = @()
  if ($env:ISCC) { $candidates += $env:ISCC }
  $candidates += @(
    "$env:ProgramFiles(x86)\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path }
  }
  try {
    $reg = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1' -ErrorAction Stop
    $p = Join-Path $reg.InstallLocation 'ISCC.exe'
    if (Test-Path $p) { return (Resolve-Path $p).Path }
  } catch {}
  throw "ISCC.exe not found. Install Inno Setup 6 or set `$env:ISCC to its path."
}

function Set-FileSignature([string]$Path, [string]$SignToolPath) {
  if (-not (Test-Path $Path)) { throw "File not found: $Path" }
  $args = @("sign","/fd","SHA256","/td","SHA256","/tr",$TimestampUrl)
  if ($CertThumbprint) {
    $args += @("/sha1",$CertThumbprint,"/sm","/s","My")
  } else {
    $args += @("/n",$CertSubject)  # (subject search uses user+machine)
  }
  $args += $Path
  Write-Host "Signing $Path ..."
  & $SignToolPath @args | Out-Host
}

# --- Locate tools ---
$SignTool = Find-SignTool
$Inf2cat = Find-Inf2cat

# --- Generate CAT for the INF ---
Write-Host "Generating catalog for $InfName ..."
& $Inf2cat /driver:. /os:10_X64,10_RS5_ARM64 | Out-Host
if (-not (Test-Path $CatName)) { throw "Catalog not generated: $CatName" }

# --- Sign the CAT (driver package signature) ---
Set-FileSignature -Path (Resolve-Path $CatName).Path -SignToolPath $SignTool

# Optional: show signature
(Get-AuthenticodeSignature $CatName).Status | Out-Host

# --- Compile the Inno Setup installer ---
$ISCC = Find-ISCC
Write-Host "Compiling installer with: $ISCC"
$defines = @()
if ($CertThumbprint) { 
    $defines += "/D""CertThumbprint=$CertThumbprint"""
} else {
    $defines += "/D""CertSubject=$CertSubject"""
}
# after locating $ISCC and building $defines, add the sign tool definition:
# For paths with spaces, use the short 8.3 path format to avoid quoting issues
$SignToolShort = (New-Object -ComObject Scripting.FileSystemObject).GetFile($SignTool).ShortPath
$toolCmd = "$SignToolShort sign /fd SHA256 /td SHA256 /tr http://timestamp.digicert.com `$f"
$tool = "/Smysig=$toolCmd"

# Build complete argument array
# Removed /Qp for verbose output to debug argument issues
Write-Host "ISCC Arguments:"
$isccArgs = @($tool) + $defines + @((Resolve-Path $IssFile).Path)
$isccArgs | ForEach-Object { Write-Host "  $_" }
& $ISCC @isccArgs | Out-Host

# Inno places output next to the script by default (per your .iss)
$Installer = Join-Path (Get-Location) "$OutputBase.exe"
if (-not (Test-Path $Installer)) {
  # Fallback: Inno may emit into .\Output by default if configured so
  $maybe = Join-Path (Get-Location) "Output\$OutputBase.exe"
  if (Test-Path $maybe) { $Installer = $maybe } else { throw "Installer not found: $OutputBase.exe" }
}

# --- Sign the installer EXE as well ---
# Inno will already sign (installer + uninstaller) via your [SignTool] block.
# This extra sign step is harmless and can help if the in-process sign is skipped.
if ($SignOutputExe) { Set-FileSignature -Path $Installer -SignToolPath $SignTool }

Write-Host "Build complete:"
Write-Host "  CAT: $((Resolve-Path $CatName).Path)"
Write-Host "  Installer: $((Resolve-Path $Installer).Path)"

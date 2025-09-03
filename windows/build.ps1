<# build.ps1
   Builds & signs the RNDIS driver package and the Inno Setup installer.
   Requires: Windows SDK (signtool), Inno Setup 6 (ISCC.exe), Windows Driver Kit (Inf2cat.exe)
#>

param(
  [string]$InfName       = "raspberrypi-rndis.inf",
  [string]$CatName       = "raspberrypi-rndis.cat",
  [string]$IssFile       = "setup.iss",
  [string]$OutputBase    = "rpi-usb-gadget-driver-setup",   # matches OutputBaseFilename in .iss
  [string]$CertSubject   = "Raspberry Pi Ltd.",             # OR set $CertThumbprint below
  [string]$CertThumbprint = "",                             # takes precedence if provided
  [string]$TimestampUrl  = "http://timestamp.digicert.com",
  [switch]$SignOutputExe = $true                            # extra sign step for the installer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Sign-File([string]$Path) {
  if (-not (Test-Path $Path)) { throw "File not found: $Path" }
  $args = @("sign","/fd","SHA256","/td","SHA256","/tr",$TimestampUrl)
  if ($CertThumbprint) {
    $args += @("/sha1",$CertThumbprint,"/sm","/s","My")
  } else {
    $args += @("/n",$CertSubject)  # (subject search uses user+machine)
  }
  $args += $Path
  Write-Host "Signing $Path ..."
  & signtool.exe @args | Out-Host
}

# --- Generate CAT for the INF ---
Write-Host "Generating catalog for $InfName ..."
& Inf2cat.exe /driver:. /os:10_X64,10_RS5_ARM64 | Out-Host
if (-not (Test-Path $CatName)) { throw "Catalog not generated: $CatName" }

# --- Sign the CAT (driver package signature) ---
Sign-File -Path (Resolve-Path $CatName).Path

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
$tool = '/Smysig=signtool.exe sign /fd SHA256 /td SHA256 /tr http://timestamp.digicert.com /sm /s My /sha1 $q' + $CertThumbprint + '$q $f'

# /Qp = quiet, progress
& $ISCC "/Qp" $tool $defines (Resolve-Path $IssFile).Path | Out-Host

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
if ($SignOutputExe) { Sign-File -Path $Installer }

Write-Host "Build complete:"
Write-Host "  CAT: $((Resolve-Path $CatName).Path)"
Write-Host "  Installer: $((Resolve-Path $Installer).Path)"

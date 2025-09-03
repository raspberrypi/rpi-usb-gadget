; ============================
; Raspberry Pi USB RNDIS Driver Installer
; ============================

#define MyAppName        "Raspberry Pi USB RNDIS Driver"
#define MyAppVersion     "1.0.0"
#define MyAppPublisher   "Raspberry Pi Ltd."
#define MyAppURL         "https://github.com/raspberrypi/rpi-usb-gadget"
#define MyAppExe         "pnputil.exe"
#define DriverInfName    "raspberrypi-rndis.inf"
#define DriverCatName    "raspberrypi-rndis.cat"
#define InstallSubDir    "Driver"

[Setup]
AppId={{F6A0C3F8-5F5E-4B86-9C15-8E7E6E6D5C9A}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
DefaultDirName={autopf}\Raspberry Pi\USB RNDIS Driver
DefaultGroupName=Raspberry Pi
OutputDir=.
OutputBaseFilename=rpi-usb-gadget-driver-setup
Compression=lzma2
SolidCompression=yes
LicenseFile=LICENSE.txt
InfoBeforeFile=README.txt
DisableDirPage=yes
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64 arm64
ArchitecturesInstallIn64BitMode=x64 arm64
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
SetupLogging=yes
; Prevent install on too-old Windows
MinVersion=10.0.0
SignedUninstaller=yes
SignTool=mysig

[Files]
; Driver files (install into {app}\Driver)
Source: "raspberrypi-rndis.inf"; DestDir: "{app}\{#InstallSubDir}"; Flags: ignoreversion
; If you have a signed CAT, include it (recommended for Secure Boot)
Source: "raspberrypi-rndis.cat"; DestDir: "{app}\{#InstallSubDir}"; Flags: ignoreversion; Permissions: users-modify
; Helper script for clean uninstall
Source: "uninstall-driver.ps1"; DestDir: "{app}\{#InstallSubDir}"; Flags: ignoreversion
; Docs shown by wizard
Source: "LICENSE.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "README.txt";  DestDir: "{app}"; Flags: ignoreversion

[Run]
; Install the driver package into the Driver Store and bind it
; Using the system pnputil from System32
Filename: "{sys}\pnputil.exe"; \
  Parameters: "/add-driver ""{app}\{#InstallSubDir}\{#DriverInfName}"" /install"; \
  StatusMsg: "Installing Raspberry Pi USB RNDIS driver..."; \
  Flags: runhidden waituntilterminated

[UninstallRun]
; Remove the driver package by finding its Published Name (oemNNN.inf)
; The PS script will delete any matching 'Raspberry Pi USB RNDIS' packages
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\{#InstallSubDir}\uninstall-driver.ps1"" -InfName ""{#DriverInfName}"" -Provider ""{#MyAppPublisher}"""; \
  Flags: runhidden waituntilterminated

[Icons]
Name: "{group}\Readme"; Filename: "{app}\README.txt"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"

[Messages]
; Tweak some wizard text

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep=ssPostInstall then begin
    MsgBox('{#MyAppName} was installed.'#13#10+
           'On Windows hosts, plug your Raspberry Pi gadget and it will bind to the RNDIS driver.'#13#10+
           'If driver signing is required, ensure the included catalog is properly signed.',
           mbInformation, MB_OK);
  end;
end;

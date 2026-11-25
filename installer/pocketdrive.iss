; PocketDrive for Windows: installer script for Inno Setup 6.
; Built by tools\release.ps1, which passes /DAppVersion=x.y.z.
;
; Installs per user (no admin prompt) to %LOCALAPPDATA%\Programs\PocketDrive,
; so the app can update itself silently later. Settings, paired phones and
; the security certificate live in %APPDATA%\PocketDrive and are kept on
; update and uninstall.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define AppExe "pocketdrive_pc.exe"
#define BuildDir "..\pc_app\build\windows\x64\runner\Release"

[Setup]
AppId={{6F3E2B1C-7A4D-4C8E-9B52-2D1F0E9A7C31}
AppName=PocketDrive
AppVersion={#AppVersion}
AppVerName=PocketDrive {#AppVersion}
AppPublisher=SepiHub
AppPublisherURL=https://github.com/SepiHub/PocketDrive
AppSupportURL=https://github.com/SepiHub/PocketDrive/issues
DefaultDirName={localappdata}\Programs\PocketDrive
DefaultGroupName=PocketDrive
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=PocketDrive-Setup-{#AppVersion}
SetupIconFile=..\pc_app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName=PocketDrive
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=force
RestartApplications=no
UsePreviousTasks=yes

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"
Name: "startup"; Description: "Start PocketDrive when I sign in to Windows (in the tray)"; GroupDescription: "Startup:"; Check: not WizardSilent
Name: "ffmpeg"; Description: "Download FFmpeg (about 100 MB) so built-in subtitle tracks in videos work"; GroupDescription: "Optional extras:"; Check: FfmpegMissing

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\PocketDrive"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\PocketDrive"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Registry]
; Same entry the app's own "Start with Windows" switch uses.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "PocketDrive"; ValueData: """{app}\{#AppExe}"" --hidden"; Tasks: startup

[Run]
Filename: "winget.exe"; Parameters: "install --id Gyan.FFmpeg --exact --silent --accept-source-agreements --accept-package-agreements"; StatusMsg: "Downloading FFmpeg (this can take a minute)..."; Tasks: ffmpeg; Flags: waituntilterminated
; Normal install: offer to open it. Silent update: start it again by itself.
Filename: "{app}\{#AppExe}"; Description: "Open PocketDrive"; Flags: nowait postinstall skipifsilent
Filename: "{app}\{#AppExe}"; Flags: nowait; Check: WizardSilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/IM {#AppExe} /F"; Flags: runhidden; RunOnceId: "StopPocketDrive"

[Code]
function FfmpegMissing: Boolean;
begin
  Result := (FileSearch('ffmpeg.exe', GetEnv('PATH')) = '') and
    not DirExists(ExpandConstant('{localappdata}\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe'));
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    RegDeleteValue(HKEY_CURRENT_USER,
      'Software\Microsoft\Windows\CurrentVersion\Run', 'PocketDrive');
end;

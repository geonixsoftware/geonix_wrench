; Inno Setup script for the Windows download (.exe installer).
;
; Built by .github/workflows/release.yml, which passes AppVersion, SourceDir
; and OutputDir on the command line. The defaults below let you compile it by
; hand from the repo root after `flutter build windows --release`:
;
;   iscc downloads\windows\installer.iss

#define AppName "Geonix Wrench"
#define AppPublisher "Geonix Software"
#define AppExe "geonix_wrench_app.exe"

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\geonix_wrench_app\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

[Setup]
; Fixed GUID — upgrades only replace the previous install if this stays put.
AppId={{E79602A5-C0A6-41F7-AD26-B92C761C3E49}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL=https://geonixsoftware.github.io/geonix/geonix_wrench.html
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=geonix-wrench-{#AppVersion}-windows
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; Flutter Windows builds are x64 only.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The whole Release folder: the .exe needs flutter_windows.dll, the plugin
; DLLs and data\ sitting beside it.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

; Build with: ISCC /DAppVersion=1.2.3 installer\libri.iss
; Expects `flutter build windows --release` to have been run first.
#ifndef AppVersion
  #define AppVersion "1.0"
#endif
#define AppName      "libri"
#define AppPublisher "Luka"
#define AppExeName   "libri.exe"
#define PublishDir   "..\build\windows\x64\runner\Release"
#define IconFile     "..\windows\runner\resources\app_icon.ico"

[Setup]
; Keep this AppId stable so new installers upgrade the existing install.
AppId={{A1B2C3D4-1234-5678-ABCD-9E8F7A6B5C4D}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\build\installer
OutputBaseFilename=libriSetup
SetupIconFile={#IconFile}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\{#AppExeName}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{commondesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent

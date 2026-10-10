#define AppId "{{8FBAF6E7-94D8-484A-B46B-DF1AE3BB824D}"
#define AppName "Screen Time Guardian"
#define AppPublisher "Mike Chong Zhou"
#define AppExeName "ScreenTimeGuardian.exe"
#ifndef SourceDir
  #define SourceDir "..\\..\\dist\\windows"
#endif
#ifndef OutputDir
  #define OutputDir "..\\..\\dist"
#endif
#define AppVersion GetFileVersion(SourceDir + "\\" + AppExeName)

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=ScreenTimeGuardian-Setup-{#AppVersion}-x64
SetupIconFile=..\ScreenTimeGuardian\Assets\stg.ico
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
CloseApplications=yes
RestartApplications=no
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "Uninstall Screen Time Guardian.cmd"

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\{#AppExeName}"; Parameters: "--uninstall-remove-startup"; Flags: runhidden waituntilterminated; Check: KeepPersonalData
Filename: "{app}\{#AppExeName}"; Parameters: "--uninstall-cleanup"; Flags: runhidden waituntilterminated; Check: DeletePersonalData

[Code]
var
  KeepDataPage: TInputOptionWizardPage;

procedure InitializeUninstall();
begin
  KeepDataPage := CreateInputOptionPage(wpWelcome,
    'Keep personal data?',
    'Choose what happens to your Screen Time Guardian data',
    '请选择是否保留个人设置和用时数据。保留后，下次安装会继续使用；删除会清除数据、日志、云端登录凭据和启动项。',
    True, False);
  KeepDataPage.Add('Keep personal settings and screen-time data / 保留个人设置和用时数据');
  KeepDataPage.Add('Permanently delete all personal data / 永久删除全部个人数据');
  KeepDataPage.SelectedValueIndex := 0;
end;

function KeepPersonalData(): Boolean;
begin
  Result := KeepDataPage.SelectedValueIndex = 0;
end;

function DeletePersonalData(): Boolean;
begin
  Result := KeepDataPage.SelectedValueIndex = 1;
end;

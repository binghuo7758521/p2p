; 无限大盘 电脑端安装包（Inno Setup 6）
; 编译前先执行 flutter build windows --release
; 编译: ISCC.exe installer.iss  （输出到 e:\p2p\p2p_desktop_setup.exe）
; 注意: 版本号与 lib/version.dart 同步（发布流程版本同步点之一）
#define MyAppName "无限大盘"
#define MyAppVersion "6.15.0"
#define MyAppExeName "p2p_desktop.exe"
#define MyAppId "8D6B1761-4DC2-4EF4-AD4D-7BB3E9028F73"

[Setup]
AppId={{8D6B1761-4DC2-4EF4-AD4D-7BB3E9028F73}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppName}
; 用户目录安装：免 UAC，且与静默升级（robocopy 覆盖程序目录）兼容
DefaultDirName={localappdata}\Programs\{#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\
OutputBaseFilename=p2p_desktop_setup
SetupIconFile=windows\runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
CloseApplications=yes

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "autostart"; Description: "开机自动启动（推荐）"; GroupDescription: "附加选项:"; Flags: checkedonce
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加选项:"; Flags: checkedonce

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
; 开机自启（HKCU 免管理员，与程序内 AutoStartService 机制一致；程序启动后也会自行维护）
; 键名必须与 auto_start.dart 的 _valueName（P2PFileAssistant）保持一致，否则会双写/残留
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "P2PFileAssistant"; ValueData: """{app}\{#MyAppExeName}"""; Tasks: autostart
; 卸载时无条件删除自启项（即使安装时未勾选，程序运行后也可能自行写入）
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "P2PFileAssistant"; Flags: uninsdeletevalue
; 清理旧版安装包遗留的自启键名（v6.10 安装包曾用"无限大盘"）
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "无限大盘"; Flags: deletevalue uninsdeletevalue

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "立即启动 {#MyAppName}"; Flags: nowait postinstall skipifsilent unchecked

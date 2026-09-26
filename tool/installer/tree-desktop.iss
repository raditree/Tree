; Tree 桌面端 Windows 安装包（Inno Setup 6 + ISPP）
;
; 手工编译（在仓库根目录）：
;   iscc /DAppName=tree /DAppExe=Tree.exe /DAppVersion=1.0.0 ^
;        /DReleaseDir="E:\programs\Tree\desktop\build\windows\x64\runner\Release" ^
;        tool\installer\tree-desktop.iss
; 或一条命令搞定：dart run tool/package_windows.dart --installer
; （脚本会先构建应用与核心，再把上面这些宏传给 iscc）
;
; 设计要点：
; 1. 必须安装**整个 Release 目录**：Flutter 引擎 DLL、data 目录、tree.exe 与
;    tree_core.exe 缺一个应用都起不来；
; 2. tree_core.exe 必须与 tree.exe **同目录**（CoreProcessLauncher 按"应用同目录"
;    找核心），装完不要手工挪动；
; 3. 用户数据（%APPDATA%\Tree：模型密钥、agent 配置、会话记录）**卸载时保留**，
;    不静默删除用户手改过的文件。

#ifndef AppName
  #define AppName "tree"
#endif

#ifndef AppExe
  #define AppExe "Tree.exe"
#endif

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#ifndef ReleaseDir
  #define ReleaseDir "..\..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{8E1F1B7A-9C4D-4E2B-9F3A-2B6F5C7D4A10}
AppName=Tree 桌面端
AppVersion={#AppVersion}
AppPublisher=Tree
DefaultDirName={autopf}\Tree Desktop
DefaultGroupName=Tree
DisableProgramGroupPage=yes
OutputDir=..\..\dist\installer
OutputBaseFilename=tree-desktop-{#AppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; 默认**每用户安装**（装到 %LOCALAPPDATA%\Programs，不需要 UAC）；需要装到
; Program Files 时用 setup.exe /ALLUSERS（会触发提权），或右键以管理员身份运行。
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
; 安装包不带数字签名：Windows 会提示"未知发布者"，这是预期行为（自签名证书反而更糟）

[Languages]
Name: "chinese"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加快捷方式："

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\Tree"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\Tree"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "启动 Tree"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; 只清理安装目录；%APPDATA%\Tree（用户配置与会话）刻意不动
Type: filesandordirs; Name: "{app}\unins000.exe"

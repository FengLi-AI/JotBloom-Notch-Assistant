Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "WinVer.nsh"
!include "x64.nsh"

Name "萌生 · JotBloom"
Caption "萌生 · JotBloom 1.0.3 测试版"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\JotBloom"
InstallDirRegKey HKCU "Software\JotBloom" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 32
BrandingText "给闪过的想法，一点空间。"
VIProductVersion "1.0.3.1"
VIAddVersionKey "ProductName" "萌生 · JotBloom"
VIAddVersionKey "FileDescription" "JotBloom Windows 10 / 11 x64 Setup"
VIAddVersionKey "FileVersion" "1.0.3 测试版"
VIAddVersionKey "ProductVersion" "1.0.3 测试版"
VIAddVersionKey "LegalCopyright" "Copyright 2026 Li Fengli"
!define MUI_ICON "${APP_ICON}"
!define MUI_UNICON "${APP_ICON}"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\JotBloom.exe"
!define MUI_FINISHPAGE_RUN_TEXT "启动萌生"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${PUBLISH_DIR}/LICENSE.txt"
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH
!insertmacro MUI_LANGUAGE "SimpChinese"

!macro CheckRunning PREFIX
Function ${PREFIX}CheckRunning
  retry:
  System::Call 'kernel32::OpenMutexW(i 0x100000, i 0, w "Local\JotBloom.Windows") p .r0'
  ${If} $0 P<> 0
    System::Call 'kernel32::CloseHandle(p r0)'
    MessageBox MB_RETRYCANCEL|MB_ICONINFORMATION "萌生正在运行。请先从系统托盘退出萌生，然后点击重试。" IDRETRY retry
    Abort
  ${EndIf}
FunctionEnd
!macroend
!insertmacro CheckRunning ""
!insertmacro CheckRunning "un."

Function .onInit
  ${IfNot} ${IsNativeAMD64}
    MessageBox MB_ICONSTOP "此安装包适用于 Intel / AMD 64 位 Windows 电脑。"
    Abort
  ${EndIf}
  ${IfNot} ${AtLeastWin10}
    MessageBox MB_ICONSTOP "萌生需要 Windows 10 22H2 或 Windows 11。"
    Abort
  ${EndIf}
  ${IfNot} U>= WinVer_BuildNumCheck 19045
    MessageBox MB_ICONSTOP "请先将 Windows 10 更新至 22H2，或使用 Windows 11。"
    Abort
  ${EndIf}
  SetRegView 64
  SetShellVarContext current
  Call CheckRunning
FunctionEnd

Function .onVerifyInstDir
  IfFileExists "$INSTDIR\*.*" 0 allowed
  IfFileExists "$INSTDIR\JotBloom-installed.txt" allowed 0
  Abort
  allowed:
FunctionEnd

Section "萌生客户端（必选）" Main
  SectionIn RO
  Call CheckRunning
  SetOutPath "$INSTDIR"
  File /r /x "._*" "${PUBLISH_DIR}/*"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\JotBloom" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\JotBloom" "DisplayName" "萌生 · JotBloom"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\JotBloom" "DisplayVersion" "1.0.3 测试版"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\JotBloom" "Publisher" "Li Fengli"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\JotBloom" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\JotBloom" "DisplayIcon" "$INSTDIR\JotBloom.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\JotBloom" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\JotBloom" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\JotBloom" "NoRepair" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\JotBloom" "EstimatedSize" ${INSTALL_KB}
  CreateDirectory "$SMPROGRAMS\萌生"
  CreateShortcut "$SMPROGRAMS\萌生\萌生.lnk" "$INSTDIR\JotBloom.exe"
  CreateShortcut "$SMPROGRAMS\萌生\卸载萌生.lnk" "$INSTDIR\Uninstall.exe"
SectionEnd

Section /o "创建桌面快捷方式" Desktop
  CreateShortcut "$DESKTOP\萌生.lnk" "$INSTDIR\JotBloom.exe"
SectionEnd

Function un.onInit
  SetRegView 64
  SetShellVarContext current
  Call un.CheckRunning
FunctionEnd

Section "Uninstall"
  Call un.CheckRunning
  Delete "$DESKTOP\萌生.lnk"
  Delete "$SMPROGRAMS\萌生\萌生.lnk"
  Delete "$SMPROGRAMS\萌生\卸载萌生.lnk"
  RMDir "$SMPROGRAMS\萌生"
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "JotBloom"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\JotBloom"
  DeleteRegKey HKCU "Software\JotBloom"
  ; Only files supplied by this installer. Data, settings and credentials are elsewhere.
  !include "${UNINSTALL_FILES}"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
SectionEnd

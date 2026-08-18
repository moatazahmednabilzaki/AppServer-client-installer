; =====================================================================
;  Oracle Forms 11g Client Deployment - Inno Setup build script
;
;  Produces ONE self-contained .exe that:
;    - prompts for elevation itself (no "right-click, Run as administrator")
;    - unpacks the payload to a temp folder that is cleaned up on exit
;    - runs 1-Automated_Fix.ps1 with the console visible so the technician
;      sees each of the 6 steps
;    - supports /SILENT and /VERYSILENT for SCCM / Intune / GPO
;    - returns the deployment's own exit code (0 = ok, 1 = failures, 5 = not elevated)
;    - drops the log and a short summary next to the .exe
;
;  BUILD (signed - the default):
;      ISCC.exe OracleFormsClient.iss
;  BUILD (unsigned, for testing before the certificate is in place):
;      ISCC.exe /DNOSIGN OracleFormsClient.iss
;
;  Requires Inno Setup 6.1 or later (GetCustomSetupExitCode).
;  All Source paths are relative to this file, so keep it in the package folder.
; =====================================================================

#define MyAppName      "Oracle Forms 11g Client Setup"
#define MyAppVersion   "1.0.0"
#define MyAppPublisher "National Technology"
#define MyScript       "1-Automated_Fix.ps1"

[Setup]
; A stable AppId. Keep it unchanged across versions.
AppId={{8F3C2A14-6D51-4B7E-9C2F-5A1E7B4D9061}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
VersionInfoVersion={#MyAppVersion}
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName}

; Nothing is permanently installed. The payload is unpacked into {tmp}, which Setup
; deletes on exit, and the PowerShell script does all the real work.
CreateAppDir=no
Uninstallable=no

; Self-elevating. This is the main UX win over Deploy.bat.
PrivilegesRequired=admin

OutputDir=dist
OutputBaseFilename=OracleForms11g_Client_Setup_{#MyAppVersion}
Compression=lzma2/max
SolidCompression=yes

WizardStyle=modern
DisableProgramGroupPage=yes
ShowLanguageDialog=no
SetupLogging=yes
MinVersion=6.1sp1

; --- Code signing ----------------------------------------------------------
; Configure ONCE in the Inno Setup IDE: Tools > Configure Sign Tools... and add a
; tool named exactly "signcmd" whose command line is something like:
;
;   "C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\signtool.exe" sign
;     /fd sha256 /tr http://timestamp.digicert.com /td sha256
;     /f "C:\certs\codesign.pfx" /p YOURPASSWORD $f
;
; Inno substitutes $f with the file being signed. Timestamping (/tr) matters: it
; keeps the signature valid after the certificate expires.
; Build with /DNOSIGN to skip signing while the certificate is being obtained.
#ifndef NOSIGN
SignTool=signcmd
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
WelcomeLabel2=This will configure this computer for Oracle Forms 11g:%n%n    - remove old Java 5 / 6%n    - install the 32-bit Java 8 runtime%n    - install the SSL certificate chain%n    - configure Edge IE Mode and the Java Control Panel%n    - install Adobe Reader%n    - pre-approve the Java browser plug-in%n%nAllow several minutes. Microsoft Edge will be closed during setup.

[Files]
; DestDir {tmp} is emptied automatically when Setup exits, so the 138 MB payload
; does not linger on the client.
Source: "{#MyScript}";                DestDir: "{tmp}"; Flags: ignoreversion
Source: "IEModeExpiryFix.vbs";        DestDir: "{tmp}"; Flags: ignoreversion
Source: "java-plugin-preapprove.reg"; DestDir: "{tmp}"; Flags: ignoreversion
Source: "*.crt";                      DestDir: "{tmp}"; Flags: ignoreversion
Source: "jre-8u*-windows-i586.exe";   DestDir: "{tmp}"; Flags: ignoreversion
Source: "AdbeRdr*.exe";               DestDir: "{tmp}"; Flags: ignoreversion

[Code]
var
  DeployExitCode: Integer;

function InitializeSetup(): Boolean;
begin
  DeployExitCode := 0;
  Result := True;
  if not FileExists(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe')) then
  begin
    SuppressibleMsgBox('Windows PowerShell was not found on this computer. Cannot continue.',
                       mbCriticalError, MB_OK, IDOK);
    Result := False;
  end;
end;

{ Arguments for the deployment script. -LogCopyDir points at the folder the .exe was
  launched from, so the technician finds the logs without digging into ProgramData. }
function BuildArgs(): String;
begin
  Result := '-NoProfile -ExecutionPolicy Bypass -File "' +
            ExpandConstant('{tmp}\{#MyScript}') + '"' +
            ' -LogCopyDir "' + ExpandConstant('{src}') + '"';
  if WizardSilent then
    Result := Result + ' -Silent';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  RC: Integer;
  ShowMode: Integer;
  SummaryPath: String;
begin
  if CurStep <> ssPostInstall then
    Exit;

  { Visible console in interactive mode - that IS the progress display.
    Hidden when running /SILENT or /VERYSILENT. }
  if WizardSilent then
    ShowMode := SW_HIDE
  else
  begin
    ShowMode := SW_SHOW;
    WizardForm.StatusLabel.Caption :=
      'Deploying Oracle Forms 11g client components. This can take several minutes...';
    WizardForm.ProgressGauge.Style := npbstMarquee;
  end;

  if Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
          BuildArgs(), ExpandConstant('{tmp}'), ShowMode, ewWaitUntilTerminated, RC) then
    DeployExitCode := RC
  else
    DeployExitCode := 99;   { could not launch PowerShell at all }

  if not WizardSilent then
    WizardForm.ProgressGauge.Style := npbstNormal;

  if DeployExitCode <> 0 then
  begin
    SummaryPath := ExpandConstant('{commonappdata}') +
                   '\AppServerClientInstaller\Logs\LAST_RESULT_' +
                   ExpandConstant('{computername}') + '.txt';
    SuppressibleMsgBox(
      'Deployment finished with problems (exit code ' + IntToStr(DeployExitCode) + ').' +
      #13#10#13#10 + 'A short summary was written to:' + #13#10 + SummaryPath +
      #13#10#13#10 + 'Please send that file to support.',
      mbError, MB_OK, IDOK);
  end;
end;

{ Surface the deployment's exit code as Setup's exit code, so SCCM / Intune can tell
  success from failure. Requires Inno Setup 6.1+. }
function GetCustomSetupExitCode(): Integer;
begin
  Result := DeployExitCode;
end;

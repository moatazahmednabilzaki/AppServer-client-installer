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
#define MyAppVersion   "1.1.0"
#define MyAppPublisher "National Technology"
#define MyScript       "1-Automated_Fix.ps1"
; Pre-filled into the URL field, and used as-is in silent mode when /URL= is omitted.
#define DefaultUrl     "https://100.74.53.100/forms/frmservlet?config=LDM"
; Setup exit codes for unusable input. Kept above Inno's own range (0-8) so they can
; never be mistaken for 5 = cancelled, 6 = terminated, 7 = aborted while preparing.
#define EXIT_BAD_URL   10
#define EXIT_BAD_CODE  11

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
WelcomeLabel2=This will configure this computer for Oracle Forms 11g:%n%n    - remove old Java 5 / 6%n    - install the 32-bit Java 8 runtime%n    - install the SSL certificate chain%n    - configure Edge IE Mode and the Java Control Panel%n    - install Adobe Reader%n    - pre-approve the Java browser plug-in%n    - record the branch / lab location codes%n    - create the 'LDM' shortcut on the desktop%n%nAllow several minutes. Microsoft Edge will be closed during setup.

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
  CfgPage: TInputQueryWizardPage;

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

// Reads /NAME=value from the command line. Written out by hand rather than using
// ExpandConstant with a param constant, because the default here is a URL full of
// : / and ? characters, and this way parsing and quote-stripping stay under our
// control. Note these are // comments on purpose: a Pascal brace comment ends at the
// FIRST closing brace, so a brace appearing in the text would truncate it.
function GetParamValue(const Name, Default: String): String;
var
  i: Integer;
  s, prefix: String;
begin
  Result := Default;
  prefix := '/' + Uppercase(Name) + '=';
  for i := 1 to ParamCount do
  begin
    s := ParamStr(i);
    if Pos(prefix, Uppercase(s)) = 1 then
    begin
      Result := Copy(s, Length(prefix) + 1, MaxInt);
      if (Length(Result) >= 2) and (Result[1] = '"') and (Result[Length(Result)] = '"') then
        Result := Copy(Result, 2, Length(Result) - 2);
      Exit;
    end;
  end;
end;

{ ASCII digits only. Deliberately not a locale-aware test: an Arabic-Indic numeral
  would otherwise be accepted and stored as a code nothing downstream can parse.
  Mirrors Test-DigitsOnly in the PowerShell script. }
function IsAsciiDigits(const S: String): Boolean;
var
  i: Integer;
begin
  Result := Length(S) > 0;
  for i := 1 to Length(S) do
    if (S[i] < '0') or (S[i] > '9') then
    begin
      Result := False;
      Exit;
    end;
end;

function LooksLikeUrl(const S: String): Boolean;
var
  L: String;
begin
  L := Lowercase(Trim(S));
  Result := ((Pos('http://', L) = 1) and (Length(L) > Length('http://'))) or
            ((Pos('https://', L) = 1) and (Length(L) > Length('https://')));
end;

procedure InitializeWizard();
begin
  CfgPage := CreateInputQueryPage(wpWelcome,
    'Deployment Settings',
    'Confirm the application address, and add the location codes if required.',
    'The URL is required and drives every step: Edge IE Mode, Trusted Sites, the Java exception list and the desktop shortcut. The two location codes are optional - leave them blank and the registry is left untouched.');
  CfgPage.Add('Application URL (required):', False);
  CfgPage.Add('Branch location code (digits only, optional):', False);
  CfgPage.Add('Lab location code (digits only, optional):', False);
  { Pre-filled from the command line when given, otherwise the shipped default }
  CfgPage.Values[0] := GetParamValue('URL', '{#DefaultUrl}');
  CfgPage.Values[1] := GetParamValue('BRANCH', '');
  CfgPage.Values[2] := GetParamValue('LAB', '');
end;

// Returns '' when the three settings are usable, otherwise the reason.
// EXIT_BAD_URL / EXIT_BAD_CODE are deliberately outside Inno's own documented exit
// code range (0-8), so "Setup could not use your input" is never confused with
// Inno's built-in 5 = cancelled, 6 = forcefully terminated, 7 = aborted while preparing.
function ValidateSettings(const U, B, L: String; var Code: Integer): String;
begin
  Result := '';
  Code := 0;
  if not LooksLikeUrl(U) then
  begin
    Code := {#EXIT_BAD_URL};
    Result := 'The application URL is not valid: "' + U + '"' + #13#10 +
              'It must start with http:// or https://';
    Exit;
  end;
  if (B <> '') and (not IsAsciiDigits(B)) then
  begin
    Code := {#EXIT_BAD_CODE};
    Result := 'The branch location code must contain digits (0-9) only. Got: "' + B + '"';
    Exit;
  end;
  if (L <> '') and (not IsAsciiDigits(L)) then
  begin
    Code := {#EXIT_BAD_CODE};
    Result := 'The lab location code must contain digits (0-9) only. Got: "' + L + '"';
    Exit;
  end;
end;

// Interactive only. Refusing to advance is exactly right when a human is present, but
// doing the same on a silent run makes Inno abort with its generic exit code 1, which
// tells an SCCM operator nothing. Silent runs are validated in CurStepChanged instead,
// where the deployment can be skipped while still returning a meaningful exit code.
function NextButtonClick(CurPageID: Integer): Boolean;
var
  Reason: String;
  Code: Integer;
begin
  Result := True;
  if WizardSilent then Exit;
  if CurPageID <> CfgPage.ID then Exit;

  Reason := ValidateSettings(Trim(CfgPage.Values[0]), Trim(CfgPage.Values[1]),
                             Trim(CfgPage.Values[2]), Code);
  if Reason <> '' then
  begin
    // SuppressibleMsgBox, never plain MsgBox: plain MsgBox ignores /SUPPRESSMSGBOXES
    // and would wait for a click on a machine nobody is watching.
    SuppressibleMsgBox(Reason, mbError, MB_OK, IDOK);
    Result := False;
  end;
end;

{ Arguments for the deployment script. -LogCopyDir points at the folder the .exe was
  launched from, so the technician finds the logs without digging into ProgramData.
  In silent mode the wizard is never shown, so values come from the command line. }
function BuildArgs(): String;
var
  U, B, L: String;
begin
  if WizardSilent then
  begin
    U := Trim(GetParamValue('URL', '{#DefaultUrl}'));
    B := Trim(GetParamValue('BRANCH', ''));
    L := Trim(GetParamValue('LAB', ''));
  end
  else
  begin
    U := Trim(CfgPage.Values[0]);
    B := Trim(CfgPage.Values[1]);
    L := Trim(CfgPage.Values[2]);
  end;

  Result := '-NoProfile -ExecutionPolicy Bypass -File "' +
            ExpandConstant('{tmp}\{#MyScript}') + '"' +
            ' -FormsUrl "' + U + '"' +
            ' -LogCopyDir "' + ExpandConstant('{src}') + '"';
  if B <> '' then Result := Result + ' -BranchCode "' + B + '"';
  if L <> '' then Result := Result + ' -LabCode "' + L + '"';
  if WizardSilent then Result := Result + ' -Silent';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  RC: Integer;
  ShowMode: Integer;
  SummaryPath: String;
  NL: String;
  Reason: String;
  BadCode: Integer;
  U, B, L: String;
begin
  { Held in a variable because the ISPP preprocessor treats a line that STARTS with
    '#' as a preprocessor directive - a wrapped line beginning #13#10 fails to compile. }
  NL := #13#10;

  if CurStep <> ssPostInstall then
    Exit;

  // Authoritative validation. On an interactive run NextButtonClick already blocked bad
  // input, so this is the gate that matters for /SILENT and /VERYSILENT. Skipping the
  // deployment here - rather than aborting the wizard - lets Setup exit with a code
  // that says WHY, instead of Inno's generic 1.
  if WizardSilent then
  begin
    U := Trim(GetParamValue('URL', '{#DefaultUrl}'));
    B := Trim(GetParamValue('BRANCH', ''));
    L := Trim(GetParamValue('LAB', ''));
  end
  else
  begin
    U := Trim(CfgPage.Values[0]);
    B := Trim(CfgPage.Values[1]);
    L := Trim(CfgPage.Values[2]);
  end;

  Reason := ValidateSettings(U, B, L, BadCode);
  if Reason <> '' then
  begin
    DeployExitCode := BadCode;
    // The deployment script never runs, so it writes no log at all. Leave the reason
    // where support will actually look: next to the installer.
    SaveStringToFile(ExpandConstant('{src}\SETUP_INPUT_ERROR.txt'),
                     'Setup did not run. Reason:' + NL + Reason + NL, False);
    SuppressibleMsgBox('Setup cannot continue.' + NL + NL + Reason, mbError, MB_OK, IDOK);
    Exit;
  end;

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
      NL + NL + 'A short summary was written to:' + NL + SummaryPath +
      NL + NL + 'Please send that file to support.',
      mbError, MB_OK, IDOK);
  end;
end;

{ Surface the deployment's exit code as Setup's exit code, so SCCM / Intune can tell
  success from failure. Requires Inno Setup 6.1+. }
function GetCustomSetupExitCode(): Integer;
begin
  Result := DeployExitCode;
end;

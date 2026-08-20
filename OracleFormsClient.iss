; =====================================================================
;  Oracle Forms 11g Client Deployment - Inno Setup build script
;
;  Produces ONE self-contained .exe that:
;    - prompts for elevation itself (no "right-click, Run as administrator")
;    - unpacks the payload to a temp folder that is cleaned up on exit
;    - runs 1-Automated_Fix.ps1 with the console visible so the technician
;      sees each of the 11 steps
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
#define MyAppVersion   "1.2.0"
#define MyAppPublisher "National Technology"
#define MyScript       "1-Automated_Fix.ps1"
; Pre-filled into the URL field, and used as-is in silent mode when /URL= is omitted.
#define DefaultUrl     "https://100.74.53.100/forms/frmservlet?config=LDM"
; Setup exit codes for unusable input. Kept above Inno's own range (0-8) so they can
; never be mistaken for 5 = cancelled, 6 = terminated, 7 = aborted while preparing.
#define EXIT_BAD_URL   10
#define EXIT_BAD_CODE  11
#define EXIT_BAD_PRN   12
; Where the LIS folder tree is deployed on the client. The deployment script uses the
; same literal path, so change it in BOTH places or Step 9 and Step 10 will disagree.
#define LisDest        "C:\LIS"

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
WelcomeLabel2=This will configure this computer for Oracle Forms 11g:%n%n    - remove old Java 5 / 6%n    - install the 32-bit Java 8 runtime%n    - install the SSL certificate chain%n    - configure Edge IE Mode and the Java Control Panel%n    - install Adobe Reader%n    - pre-approve the Java browser plug-in%n    - record the branch / lab location codes%n    - create the 'LDM' shortcut on the desktop%n    - deploy the LIS folder to C:\LIS%n    - set the barcode / A4 printers and add the 'AutoPrint' shortcut%n%nAllow several minutes. Microsoft Edge will be closed during setup.

[Files]
; DestDir {tmp} is emptied automatically when Setup exits, so the 138 MB payload
; does not linger on the client.
Source: "{#MyScript}";                DestDir: "{tmp}"; Flags: ignoreversion
Source: "IEModeExpiryFix.vbs";        DestDir: "{tmp}"; Flags: ignoreversion
Source: "java-plugin-preapprove.reg"; DestDir: "{tmp}"; Flags: ignoreversion
Source: "*.crt";                      DestDir: "{tmp}"; Flags: ignoreversion
Source: "jre-8u*-windows-i586.exe";   DestDir: "{tmp}"; Flags: ignoreversion
Source: "AdbeRdr*.exe";               DestDir: "{tmp}"; Flags: ignoreversion
; The LIS tree, copied to C:\LIS by Step 9. createallsubdirs is what carries the
; deliberately empty folders (A4\Backup, Barcode\Backup, Barcode\Log, back, log) -
; without it Inno packs only folders that contain files, and AutoPrintFiles then
; fails at run time looking for a spool folder that was never created.
Source: "LIS\*"; DestDir: "{tmp}\LIS"; Flags: ignoreversion recursesubdirs createallsubdirs

[Code]
{ Field indices on CfgPage. Named because five positional Values[n] references
  scattered through the file is how the wrong printer ends up in the wrong key. }
const
  FLD_URL     = 0;
  FLD_BRANCH  = 1;
  FLD_LAB     = 2;
  FLD_BARCODE = 3;
  FLD_A4      = 4;

var
  DeployExitCode: Integer;
  CfgPage: TInputQueryWizardPage;
  { Answer to the "C:\LIS already exists" question, decided once before the
    deployment script is launched and read again by BuildArgs. }
  LisReplaceChoice: Boolean;

procedure AddUnique(L: TStringList; const S: String);
var
  V: String;
begin
  V := Trim(S);
  if (V <> '') and (L.IndexOf(V) < 0) then
    L.Add(V);
end;

{ HKCU\Printers\Connections stores a network printer as ",,server,printer" -
  backslashes are not legal in a registry key name, so they are encoded as commas.
  Turn it back into \\server\printer, which is the name the spooler answers to and
  therefore the name AutoPrintFiles has to be given. }
function DecodeConnectionName(const S: String): String;
var
  i: Integer;
begin
  Result := S;
  for i := 1 to Length(Result) do
    if Result[i] = ',' then
      Result[i] := '\';
end;

{ Every printer this machine can reach, from the registry rather than by shelling out
  to PowerShell or WMI: the button has to feel instant, and spawning a process from a
  wizard button is both slow and one more thing that can fail on a locked-down client.

  HKLM\SYSTEM\CurrentControlSet\Control\Print\Printers is machine-wide and is NOT
  subject to WOW64 registry redirection (only parts of SOFTWARE are), so a 32-bit
  Setup reads the real key here without needing the 64-bit view.

  Caveat worth knowing: Setup runs elevated, so HKEY_CURRENT_USER is the hive of the
  ADMIN account. Per-user network printer connections belonging to the logged-on
  standard user therefore may not be listed. Machine printers always are, and the
  field stays free text precisely so an unlisted name can still be typed in. }
function GetPrinterNames(): TStringList;
var
  Names: TArrayOfString;
  i: Integer;
begin
  Result := TStringList.Create;

  if RegGetSubkeyNames(HKEY_LOCAL_MACHINE,
       'SYSTEM\CurrentControlSet\Control\Print\Printers', Names) then
    for i := 0 to GetArrayLength(Names) - 1 do
      AddUnique(Result, Names[i]);

  if RegGetSubkeyNames(HKEY_CURRENT_USER, 'Printers\Connections', Names) then
    for i := 0 to GetArrayLength(Names) - 1 do
      AddUnique(Result, DecodeConnectionName(Names[i]));

  { Sorted after the fact: sorting during insertion would make IndexOf-based
    de-duplication depend on the sort, which is a subtle way to lose entries. }
  Result.Sort;
end;

{ Modal printer chooser. Returns '' when cancelled or when nothing is installed, and
  the caller then leaves the field exactly as the technician typed it.

  Keyboard flow is arrow keys then Enter, which works because the OK button is the
  form's Default. There is deliberately no double-click shortcut: TSetupForm does not
  expose ModalResult to Pascal Script, so a dbl-click handler cannot close the form. }
function PickPrinter(const Title, Current: String): String;
var
  L: TStringList;
  i: Integer;
  PrnForm: TSetupForm;
  PrnList: TNewListBox;
  Lbl: TNewStaticText;
  OKBtn, CancelBtn: TNewButton;
  BtnW: Integer;
begin
  Result := '';
  L := GetPrinterNames();
  try
    if L.Count = 0 then
    begin
      SuppressibleMsgBox('No printers are installed on this computer.' + #13#10#13#10 +
        'Install the printer first, then run Setup again - or type the exact printer ' +
        'name into the field by hand.', mbInformation, MB_OK, IDOK);
      Exit;
    end;

    { Fourth argument False = do not grow vertically: the list box is the only control
      that could size, and letting it stretch leaves the buttons floating. }
    PrnForm := CreateCustomForm(ScaleX(430), ScaleY(310), False, False);
    try
      PrnForm.Caption := Title;

      Lbl := TNewStaticText.Create(PrnForm);
      Lbl.Parent := PrnForm;
      Lbl.Left := ScaleX(10);
      Lbl.Top := ScaleY(10);
      Lbl.Caption := 'Printers found on this computer (' + IntToStr(L.Count) + '):';

      PrnList := TNewListBox.Create(PrnForm);
      PrnList.Parent := PrnForm;
      PrnList.Left := ScaleX(10);
      PrnList.Top := ScaleY(32);
      PrnList.Width := PrnForm.ClientWidth - ScaleX(2 * 10);
      PrnList.Height := PrnForm.ClientHeight - ScaleY(32 + 23 + 10 + 10);
      for i := 0 to L.Count - 1 do
        PrnList.Items.Add(L[i]);

      { Re-select whatever the field already holds, so reopening the dialog does not
        silently move the selection to the first printer in the list. }
      PrnList.ItemIndex := PrnList.Items.IndexOf(Current);
      if PrnList.ItemIndex < 0 then
        PrnList.ItemIndex := 0;

      OKBtn := TNewButton.Create(PrnForm);
      OKBtn.Parent := PrnForm;
      OKBtn.Caption := 'OK';
      OKBtn.Left := PrnForm.ClientWidth - ScaleX(75 + 6 + 75 + 10);
      OKBtn.Top := PrnForm.ClientHeight - ScaleY(23 + 10);
      OKBtn.Height := ScaleY(23);
      OKBtn.ModalResult := mrOk;
      OKBtn.Default := True;

      CancelBtn := TNewButton.Create(PrnForm);
      CancelBtn.Parent := PrnForm;
      CancelBtn.Caption := 'Cancel';
      CancelBtn.Left := PrnForm.ClientWidth - ScaleX(75 + 10);
      CancelBtn.Top := PrnForm.ClientHeight - ScaleY(23 + 10);
      CancelBtn.Height := ScaleY(23);
      CancelBtn.ModalResult := mrCancel;
      CancelBtn.Cancel := True;

      { Widths from the captions, so a translated 'Cancel' cannot be clipped }
      BtnW := PrnForm.CalculateButtonWidth([OKBtn.Caption, CancelBtn.Caption]);
      OKBtn.Width := BtnW;
      CancelBtn.Width := BtnW;

      { Focus the list, not the OK button, so the arrow keys work immediately }
      PrnForm.ActiveControl := PrnList;
      PrnForm.FlipAndCenterIfNeeded(True, WizardForm, False);

      if PrnForm.ShowModal() = mrOk then
        if PrnList.ItemIndex >= 0 then
          Result := PrnList.Items[PrnList.ItemIndex];
    finally
      PrnForm.Free();
    end;
  finally
    L.Free;
  end;
end;

procedure BarcodeBrowseClick(Sender: TObject);
var
  S: String;
begin
  S := PickPrinter('Select the barcode printer', Trim(CfgPage.Values[FLD_BARCODE]));
  if S <> '' then
    CfgPage.Values[FLD_BARCODE] := S;
end;

procedure A4BrowseClick(Sender: TObject);
var
  S: String;
begin
  S := PickPrinter('Select the A4 printer', Trim(CfgPage.Values[FLD_A4]));
  if S <> '' then
    CfgPage.Values[FLD_A4] := S;
end;

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

{ Shrinks an edit box to make room for a button, and returns the button already
  positioned beside it. Driven off the edit's own bounds rather than hard-coded
  coordinates so it stays aligned at 125% and 150% display scaling. }
function AddBrowseButton(EditIndex: Integer): TNewButton;
var
  E: TPasswordEdit;
  BtnW: Integer;
begin
  E := CfgPage.Edits[EditIndex];
  BtnW := ScaleX(86);

  E.Width := E.Width - BtnW - ScaleX(6);

  Result := TNewButton.Create(CfgPage);
  Result.Parent := CfgPage.Surface;
  Result.Left := E.Left + E.Width + ScaleX(6);
  Result.Top := E.Top - ScaleY(1);
  Result.Width := BtnW;
  Result.Height := E.Height + ScaleY(2);
  Result.Caption := 'Printers...';
end;

procedure InitializeWizard();
var
  BarcodeBtn, A4Btn: TNewButton;
begin
  { The description is kept short on purpose: it shares the page surface with the
    input fields, and five fields plus the old three-line paragraph overflows the
    page at 125% scaling. }
  CfgPage := CreateInputQueryPage(wpWelcome,
    'Deployment Settings',
    'Confirm the application address, then add the location codes and printers if required.',
    'Only the URL is required - it drives Edge IE Mode, Trusted Sites, the Java exception list and the LDM shortcut. Everything below it is optional; blank fields are left alone.');
  CfgPage.Add('Application URL (required):', False);
  CfgPage.Add('Branch location code (digits only, optional):', False);
  CfgPage.Add('Lab location code (digits only, optional):', False);
  CfgPage.Add('Barcode printer (optional):', False);
  CfgPage.Add('A4 printer (optional):', False);

  { Pre-filled from the command line when given, otherwise the shipped default }
  CfgPage.Values[FLD_URL]     := GetParamValue('URL', '{#DefaultUrl}');
  CfgPage.Values[FLD_BRANCH]  := GetParamValue('BRANCH', '');
  CfgPage.Values[FLD_LAB]     := GetParamValue('LAB', '');
  CfgPage.Values[FLD_BARCODE] := GetParamValue('BARCODEPRINTER', '');
  CfgPage.Values[FLD_A4]      := GetParamValue('A4PRINTER', '');

  BarcodeBtn := AddBrowseButton(FLD_BARCODE);
  BarcodeBtn.OnClick := @BarcodeBrowseClick;

  A4Btn := AddBrowseButton(FLD_A4);
  A4Btn.OnClick := @A4BrowseClick;
end;

// Returns '' when the three settings are usable, otherwise the reason.
// EXIT_BAD_URL / EXIT_BAD_CODE are deliberately outside Inno's own documented exit
// code range (0-8), so "Setup could not use your input" is never confused with
// Inno's built-in 5 = cancelled, 6 = forcefully terminated, 7 = aborted while preparing.
function ValidateSettings(const U, B, L, BP, AP: String; var Code: Integer): String;
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
  { A double quote would terminate the quoted argument early when the printer name is
    handed to powershell.exe, silently truncating the name or shifting every later
    argument by one. Real printer names never contain one, so refusing is safe. }
  if Pos('"', BP) > 0 then
  begin
    Code := {#EXIT_BAD_PRN};
    Result := 'The barcode printer name cannot contain a double quote (").' + #13#10 +
              'Got: ' + BP;
    Exit;
  end;
  if Pos('"', AP) > 0 then
  begin
    Code := {#EXIT_BAD_PRN};
    Result := 'The A4 printer name cannot contain a double quote (").' + #13#10 +
              'Got: ' + AP;
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

  Reason := ValidateSettings(Trim(CfgPage.Values[FLD_URL]), Trim(CfgPage.Values[FLD_BRANCH]),
                             Trim(CfgPage.Values[FLD_LAB]), Trim(CfgPage.Values[FLD_BARCODE]),
                             Trim(CfgPage.Values[FLD_A4]), Code);
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
  U, B, L, BP, AP: String;
begin
  if WizardSilent then
  begin
    U  := Trim(GetParamValue('URL', '{#DefaultUrl}'));
    B  := Trim(GetParamValue('BRANCH', ''));
    L  := Trim(GetParamValue('LAB', ''));
    BP := Trim(GetParamValue('BARCODEPRINTER', ''));
    AP := Trim(GetParamValue('A4PRINTER', ''));
  end
  else
  begin
    U  := Trim(CfgPage.Values[FLD_URL]);
    B  := Trim(CfgPage.Values[FLD_BRANCH]);
    L  := Trim(CfgPage.Values[FLD_LAB]);
    BP := Trim(CfgPage.Values[FLD_BARCODE]);
    AP := Trim(CfgPage.Values[FLD_A4]);
  end;

  Result := '-NoProfile -ExecutionPolicy Bypass -File "' +
            ExpandConstant('{tmp}\{#MyScript}') + '"' +
            ' -FormsUrl "' + U + '"' +
            ' -LogCopyDir "' + ExpandConstant('{src}') + '"';
  if B  <> '' then Result := Result + ' -BranchCode "' + B + '"';
  if L  <> '' then Result := Result + ' -LabCode "' + L + '"';
  if BP <> '' then Result := Result + ' -BarcodePrinter "' + BP + '"';
  if AP <> '' then Result := Result + ' -A4Printer "' + AP + '"';
  { Only ever passed when the technician said Yes (or a silent caller opted in with
    /LISREPLACE=1). Absent means Step 9 leaves an existing C:\LIS alone. }
  if LisReplaceChoice then Result := Result + ' -LisReplace';
  if WizardSilent then Result := Result + ' -Silent';
end;

{ Asked once, immediately before the deployment script runs, and only when there is
  actually something to overwrite.

  The default answer is No in every ambiguous case - a suppressed message box, or a
  silent run without /LISREPLACE=1. C:\LIS\Barcode\Backup, C:\LIS\Barcode\Log and
  C:\LIS\back accumulate real print history on a working till, so an unattended
  re-run must never wipe them just because nobody was there to answer. }
function DecideLisReplace(): Boolean;
var
  P: String;
begin
  Result := False;

  if not DirExists('{#LisDest}') then
  begin
    { Nothing there yet: Step 9 creates the folder regardless, and the flag is
      irrelevant, so leave it off rather than implying a replacement happened. }
    Exit;
  end;

  if WizardSilent then
  begin
    P := Uppercase(Trim(GetParamValue('LISREPLACE', '')));
    Result := (P = '1') or (P = 'YES') or (P = 'TRUE');
    Exit;
  end;

  Result := SuppressibleMsgBox(
    'The folder {#LisDest} already exists on this computer.' + #13#10#13#10 +
    'Replace it with the copy from this installer?' + #13#10#13#10 +
    'Yes  -  overwrite the files this package ships. Backup and Log files already in' + #13#10 +
    '          {#LisDest} are kept, not deleted.' + #13#10#13#10 +
    'No   -  leave {#LisDest} exactly as it is and carry on with the rest of Setup.' + #13#10 +
    '          The barcode and A4 printer names are still written to the existing' + #13#10 +
    '          configuration file.',
    mbConfirmation, MB_YESNO, IDNO) = IDYES;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  RC: Integer;
  ShowMode: Integer;
  SummaryPath: String;
  NL: String;
  Reason: String;
  BadCode: Integer;
  U, B, L, BP, AP: String;
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
    U  := Trim(GetParamValue('URL', '{#DefaultUrl}'));
    B  := Trim(GetParamValue('BRANCH', ''));
    L  := Trim(GetParamValue('LAB', ''));
    BP := Trim(GetParamValue('BARCODEPRINTER', ''));
    AP := Trim(GetParamValue('A4PRINTER', ''));
  end
  else
  begin
    U  := Trim(CfgPage.Values[FLD_URL]);
    B  := Trim(CfgPage.Values[FLD_BRANCH]);
    L  := Trim(CfgPage.Values[FLD_LAB]);
    BP := Trim(CfgPage.Values[FLD_BARCODE]);
    AP := Trim(CfgPage.Values[FLD_A4]);
  end;

  Reason := ValidateSettings(U, B, L, BP, AP, BadCode);
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

  { Asked here rather than on the settings page so the technician answers it as part of
    the install, and only after the input is known to be usable. BuildArgs reads the
    answer, so this must happen before the Exec below. }
  LisReplaceChoice := DecideLisReplace();

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

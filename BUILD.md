# Building the single-EXE installer

Produces one self-contained `OracleForms11g_Client_Setup_1.0.0.exe` (~135–140 MB)
for sending to customers.

## Prerequisites

1. **Inno Setup 6.1 or later** — https://jrsoftware.org/isdl.php (free).
   6.1+ is required for `GetCustomSetupExitCode`.
2. The complete package folder, including the two payload binaries that are **not**
   in git:
   - `jre-8u241-windows-i586.exe`
   - `AdbeRdr11010_en_US.exe`
3. For signing: `signtool.exe` (Windows SDK) and your code-signing certificate.

## One-time: configure the signing tool

In the Inno Setup IDE: **Tools → Configure Sign Tools… → Add**, name it exactly
`signcmd`, with a command line like:

```
"C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\signtool.exe" sign /fd sha256 /tr http://timestamp.digicert.com /td sha256 /f "C:\certs\codesign.pfx" /p YOURPASSWORD $f
```

Inno replaces `$f` with the file being signed.

**Always timestamp** (`/tr` + `/td`). Without it the signature stops validating the
day the certificate expires; with it, signatures stay valid indefinitely.

Do not commit the `.pfx` or its password to this repo.

## Build

```bash
ISCC.exe OracleFormsClient.iss
```

Unsigned build, for testing before the certificate is in place:

```bash
ISCC.exe /DNOSIGN OracleFormsClient.iss
```

Output lands in `dist\`.

## Customer-facing usage

| Command | Behaviour |
|---|---|
| Double-click the exe | UAC prompt, wizard, visible console showing all 6 steps, summary at the end |
| `Setup.exe /SILENT` | Progress window only, no prompts, console hidden |
| `Setup.exe /VERYSILENT` | Completely unattended — for SCCM / Intune / GPO |
| `Setup.exe /LOG="C:\path\inno.log"` | Also write Inno's own extraction log |

The exe **self-elevates**, so there is no need to tell customers to right-click and
Run as administrator.

> **On the embedded manifest.** The compiled exe's manifest says
> `requestedExecutionLevel level="asInvoker"`, not `requireAdministrator`. This is
> correct and expected: Inno Setup performs elevation at *runtime* (it re-launches
> itself with the `runas` verb) rather than through the manifest. Verified by
> extracting the manifest from Inno Setup's **own** installer, which unquestionably
> requires admin and is likewise `asInvoker`. Do not "fix" this.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Deployment ran but one or more steps failed |
| 5 | Not elevated (UAC declined) |
| 99 | PowerShell could not be launched |
| 2, 3, 4… | Inno Setup's own codes (cancelled, init failure) — see Inno docs |

## Logs

Three places, in decreasing order of usefulness for support:

1. `%ProgramData%\AppServerClientInstaller\Logs\LAST_RESULT_<COMPUTERNAME>.txt`
   — the short summary. **This is the file to ask a customer for.** A few KB.
2. Next to the exe — the same summary plus the full transcript are copied there
   automatically, if that location is writable.
3. `%ProgramData%\AppServerClientInstaller\Logs\deploy_<COMPUTERNAME>_<timestamp>.log`
   — full transcript of every step.

## Verified build

Built and tested with Inno Setup 6.7.3:

| Check | Result |
|---|---|
| Compile | Success, ~24–90 s (first build is slowest) |
| Output size | 136.7 MB from a 137.7 MB payload |
| Payload extraction | Unpacks to `%TEMP%\is-XXXXXXXX.tmp`, script runs from there |
| Temp cleanup | No `is-*.tmp` folder left behind |
| `/VERYSILENT` | `-Silent` correctly passed to the script |
| `-LogCopyDir` quoting | Survives a launch folder named `Launch Folder With Spaces (x86) & more` |
| Exit code passthrough | Script exit code surfaces as Setup's exit code (verified with a script returning 42) |

The end-to-end run was done with `PrivilegesRequired=lowest` so the deployment
script's own elevation guard aborted it at exit 5 — this exercised extraction,
argument passing and exit-code capture without altering the build machine.

**Not yet verified on a real client:** the UAC prompt itself, and the six deployment
steps actually running to completion. Do that once on a test client before any
fleet rollout.

### Gotcha if you edit the .iss

The ISPP preprocessor treats a line whose first non-whitespace character is `#` as a
preprocessor directive. A wrapped Pascal string starting with `#13#10` fails to
compile with *"Unknown preprocessor directive"*. That is why the `[Code]` section
assigns `NL := #13#10;` and concatenates `NL` instead.

## Notes

- The payload is unpacked into Setup's temp folder and deleted when it exits;
  nothing is permanently installed by the wrapper itself.
- Expect ~137 MB. Both payload binaries are already compressed, so LZMA2 has little
  left to squeeze (137.7 MB in, 136.7 MB out). Too large for email — use a download
  link, share or USB.
- **Free disk space on the client:** the exe needs roughly 140 MB to unpack, on top
  of what Java 8 and Adobe Reader themselves consume. Budget ~700 MB free on `C:`.
- The built exe is **not** committed to git (`dist/` is ignored, and it exceeds
  GitHub's 100 MB file limit). Build it from source when you need it.
- **Unsigned builds will trigger SmartScreen** ("Windows protected your PC") and
  may be quarantined by AV. That is expected for an unsigned binary that uninstalls
  Java, writes HKLM policy, imports root certificates and re-enables MD5 and
  TLS 1.0. A signed build with an OV certificate largely avoids this; EV gets
  SmartScreen reputation immediately.
- To retarget a different customer, edit only the CONFIG block at the top of
  `1-Automated_Fix.ps1` (`$ServerHost`, `$FormsConfig`) and **bump `$SiteListVer`** —
  Edge caches the IE Mode site list by version number and will otherwise keep serving
  the old one.

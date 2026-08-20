# Building the single-EXE installer

Produces one self-contained `OracleForms11g_Client_Setup_1.2.0.exe` (~137 MB)
for sending to customers.

## Prerequisites

1. **Inno Setup 6.1 or later** — https://jrsoftware.org/isdl.php (free).
   6.1+ is required for `GetCustomSetupExitCode`.
2. The complete package folder, including the two payload binaries that are **not**
   in git:
   - `jre-8u241-windows-i586.exe`
   - `AdbeRdr11010_en_US.exe`
3. The `LIS\` folder tree. The `[Files]` entry for it is not optional — if `LIS\*`
   matches nothing, **compilation fails** rather than quietly shipping without it.

   `LIS\` ships five deliberately empty folders (`A4\Backup`, `Barcode\Backup`,
   `Barcode\Log`, `back`, `log`) that `AutoPrintFiles` expects to exist. Git cannot
   store an empty directory, so each one carries a zero-byte `.gitkeep`. Do not delete
   them: without the placeholders a fresh clone loses those folders, `createallsubdirs`
   then has nothing to pack, and `AutoPrintFiles` fails at run time on a client looking
   for a spool folder that was never created.

   The placeholders are only in the leaf folders. `A4\` and `Barcode\` survive in git
   via their children, which matters because those two *are* the folders
   `AutoPrintFiles` watches for files to print (`BarcodFolder`, `A4Folder`) — a stray
   file at their top level would be picked up as a print job.
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
| Double-click the exe | UAC prompt, settings page, then a visible console showing all 11 steps |
| `Setup.exe /SILENT` | Progress window only, no prompts, console hidden |
| `Setup.exe /VERYSILENT` | Completely unattended — for SCCM / Intune / GPO |
| `Setup.exe /LOG="C:\path\inno.log"` | Also write Inno's own extraction log |

### Settings page (first page of the wizard)

Five fields. The URL is required; everything else is optional and, when left blank,
the corresponding setting is not touched at all.

| Field | Switch | Effect |
|---|---|---|
| Application URL | `/URL=` | Drives **every** step: Edge IE Mode site list, Trusted Sites zone, Java exception list, the VBS launcher and the LDM shortcut |
| Branch location code | `/BRANCH=` | REG_SZ `branch_code` under `HKLM\SOFTWARE\WOW6432Node\branch_code` |
| Lab location code | `/LAB=` | REG_SZ `lab_location` under `HKLM\SOFTWARE\WOW6432Node\lab_location` |
| Barcode printer | `/BARCODEPRINTER=` | `BarcodPrinter` value in `C:\LIS\app\AutoPrintFiles.exe.config` |
| A4 printer | `/A4PRINTER=` | `A4Printer` value in the same file |

Each printer field has a **Printers…** button beside it that lists the printers
installed on the machine, so the name does not have to be typed by hand. The field
stays editable, because Setup runs elevated and therefore reads the *administrator's*
`HKCU`: a network printer mapped only in the logged-on standard user's profile may not
appear in the list, and can still be typed in.

Both printer fields are optional. A blank field leaves the value already in the config
file alone — that is what makes it safe to change only the A4 printer on a machine
whose barcode printer is already correct.

`BarcodPrinter` is spelled without the trailing `e`. That is the spelling in the
shipped config and the one `AutoPrintFiles.exe` reads, so it is preserved deliberately.
`BarcodePrinter` is accepted as an alias if a client's config was hand-corrected at
some point; whichever key already exists is the one updated, and the script never adds
one spelling alongside the other.

### The C:\LIS folder

Step 9 copies the packaged `LIS` tree to `C:\LIS`. If that folder already exists,
Setup asks whether to replace it:

- **Yes** — the files this package ships are overwritten. Files the client put there
  are **not** deleted: the copy is `robocopy /E` with no `/PURGE`, so accumulated
  `Barcode\Backup`, `Barcode\Log` and `back` contents survive.
- **No** — `C:\LIS` is left exactly as it is and Setup carries on. Step 10 still
  writes the printer names into the existing config file.

In silent mode the question cannot be asked, so the answer defaults to **No**. Pass
`/LISREPLACE=1` to opt in explicitly. This is deliberate: an unattended re-run must
never overwrite a working till's folder just because nobody was there to answer.

The empty folders in the tree (`A4\Backup`, `Barcode\Backup`, `Barcode\Log`, `back`,
`log`) are shipped on purpose — `AutoPrintFiles` expects them to exist. They survive
compilation because the `[Files]` entry uses `createallsubdirs`; without that flag Inno
packs only folders containing files.

Unattended example:

```bash
OracleForms11g_Client_Setup_1.2.0.exe /VERYSILENT /SUPPRESSMSGBOXES /URL="https://100.74.53.100/forms/frmservlet?config=LDM" /BRANCH=00123 /LAB=987
```

Notes:

- Codes must be **ASCII digits only**. Arabic-Indic numerals are rejected on purpose —
  they would otherwise be stored as a "numeric" code nothing downstream can parse.
  Leading zeros are preserved (`00123` stays `00123`), since the value is a REG_SZ.
- Existing values are **updated**, not duplicated. The script reads the value back
  after writing and logs the before/after.
- Invalid input in silent mode **does not deploy anything**. Setup exits with the code
  below and writes `SETUP_INPUT_ERROR.txt` next to the exe explaining why, because the
  deployment script never runs and so never produces a log.
- A URL with a port works: `https://host:8443/...` keeps the port in the site list and
  the Java exception list, while the Trusted Sites zone entry gets the bare host.

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
| 6 | The URL reached the script but was unusable |
| **10** | Setup rejected the URL — nothing was deployed |
| **11** | Setup rejected a location code — nothing was deployed |
| **12** | Setup rejected a printer name (it contained a `"`) — nothing was deployed |
| 99 | PowerShell could not be launched |
| 2, 3, 4, 7, 8 | Inno Setup's own codes (cancelled, init failure, aborted) — see Inno docs |

10, 11 and 12 sit deliberately above Inno's own 0–8 range so "bad input" can never be
confused with Inno's 5 = cancelled, 6 = terminated or 7 = aborted while preparing.

A double quote in a printer name is refused rather than escaped: the name is handed to
`powershell.exe` inside a quoted argument, where a stray `"` would truncate the name or
shift every later argument by one. Real printer names never contain one.

## Logs

Three places, in decreasing order of usefulness for support:

1. `%ProgramData%\AppServerClientInstaller\Logs\LAST_RESULT_<COMPUTERNAME>.txt`
   — the short summary. **This is the file to ask a customer for.** A few KB.
2. Next to the exe — the same summary plus the full transcript are copied there
   automatically, if that location is writable.
3. `%ProgramData%\AppServerClientInstaller\Logs\deploy_<COMPUTERNAME>_<timestamp>.log`
   — full transcript of every step.

## Release status

| Version | Status |
|---|---|
| **v1.2.0** | Compiles clean. Steps 9–11 verified in isolation (see below). The **wizard page and the Printers… dialog have not been clicked through by a human yet** — that is the one thing to check first on the next real deployment. |
| v1.1.0 | **Confirmed working on a client by the user, 2026-08-18.** Reported stable and successful. This supersedes the "not clicked through by a human" caveat recorded in the v1.1.0 git tag message, which was written before that confirmation. |
| v1.0.1 | Superseded. Confirmed working on WIN-0RUCE62NOTH (Server 2022): all steps, exit 0, 99 s. |

### Fixed in v1.2.0: the mixed-code setting never actually applied

Every version up to and including v1.1.0 wrote
`deployment.security.mixcode=HIDE_UNTRUSTED` into `deployment.properties`.
**`HIDE_UNTRUSTED` is not a value Java recognises.** The four it accepts, confirmed
against the `MIXCODE_MODE_*` constants in `com.sun.deploy.config.Config` inside
`deploy.jar`, are:

| Value | Java Control Panel radio button |
|---|---|
| `ENABLE` | Enable — show warning if needed *(Java's default)* |
| `HIDE_RUN` | Enable — hide warning and run with protections |
| **`HIDE_CANCEL`** | **Enable — hide warning and don't run untrusted code** |
| `DISABLE` | Disable verification (not recommended) |

An unrecognised value is silently discarded and Java falls back to `ENABLE`, so the
mixed code warning kept appearing on clients even though the property looked set.
v1.2.0 writes `HIDE_CANCEL`.

**This means every client already deployed with v1.0.x or v1.1.0 has the wrong setting
and needs v1.2.0 re-run on it** to pick up the fix. The properties file is rewritten
wholesale on each run, so a plain re-run is enough.

The value is deliberately **not** locked (no `.locked` suffix), matching the existing
"set properties without locking them, allowing manual override" design. Add
`deployment.security.mixcode.locked` to `$props` in Step 4 if it should be greyed out
in the Control Panel instead.

### What was verified for v1.2.0, and how

Steps 9–11 were exercised by slicing the step code verbatim out of
`1-Automated_Fix.ps1` and running it against the payload extracted from a real
compiled installer. Cases covered:

| Case | Result |
|---|---|
| Fresh copy, `C:\LIS` absent | Created, all 5 empty folders present, robocopy exit 1 treated as success |
| Folder exists, replace declined | Copy skipped, **config still updated**, client files untouched |
| Folder exists, replace approved | Files overwritten, client files in `Barcode\Backup` and `log` **survived** |
| Neither printer supplied | Config left byte-for-byte alone |
| Only the A4 printer supplied | Barcode value untouched |
| Printer name containing `& < >` | Escaped as `&amp; &lt; &gt;`, file still parses as valid config XML |
| Empty folders survive compilation | Confirmed by extracting a payload-only test installer |

Step 11 initially reported a failure in that harness because it ran unelevated and
`C:\Users\Public\Desktop` is not writable without admin. Re-run against a writable
path it produced a correct shortcut (target, working directory, icon, description all
right). The real Setup is `PrivilegesRequired=admin`, and Step 8 has been creating a
shortcut in the same folder on real clients since v1.1.0.

Still not exercised on any version: the **Java 5 / 6 removal path** (see below), and
now also the **wizard UI itself** — the five-field settings page at 125%/150% display
scaling, and the Printers… dialog against a real printer list.

Still not exercised by any run so far, on any version: the **Java 5 / 6 removal path**.
Every machine tested has been clean, so the `msiexec` / WMI uninstall branch in Step 1
has never actually executed. It remains the least proven code in the package, and a
confirmation of a normal deployment does not cover it — that needs a client that
genuinely has old Java installed.

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
- Expect ~137 MB. Too large for email — use a download link, share or USB.

### Do not bother tuning compression

Measured, not guessed:

| Setting | Output | Compile time |
|---|---|---|
| `lzma2/max` (current) | 136.71 MB | 24 s |
| `lzma2/ultra64` | 136.59 MB | 227 s |

**0.12 MB saved for a 9.4x longer compile.** Both payload binaries are already
compressed archives (137.7 MB of input becomes ~135.5 MB of compressed data — a 1.6%
gain), so there is essentially no entropy left for LZMA2 to remove. Keep
`lzma2/max`.

The only real lever is **what you include**, not how you compress it:

| Contents | Approx. exe size |
|---|---|
| JRE + Adobe (current) | 137 MB |
| JRE only, Adobe shipped separately or fetched | 65 MB |

Worth knowing: Step 5 already **skips** Adobe when any Acrobat or Reader is present,
so on those machines the 72 MB of Adobe payload is shipped and unpacked for nothing.
If most target machines already have a PDF reader, splitting Adobe into a second
optional exe is the biggest available win.

Re-zipping the exe for transport does not help — it is already compressed.
- **Free disk space on the client:** the exe needs roughly 140 MB to unpack, on top
  of what Java 8 and Adobe Reader themselves consume. Budget ~700 MB free on `C:`.
- The built exe is **not** committed to git (`dist/` is ignored, and it exceeds
  GitHub's 100 MB file limit). Build it from source when you need it.
- **Unsigned builds will trigger SmartScreen** ("Windows protected your PC") and
  may be quarantined by AV. That is expected for an unsigned binary that uninstalls
  Java, writes HKLM policy, imports root certificates and re-enables MD5 and
  TLS 1.0. A signed build with an OV certificate largely avoids this; EV gets
  SmartScreen reputation immediately.
- **Retargeting a customer no longer needs a code edit.** Type the URL on the settings
  page, or pass `/URL=`. The old manual `$SiteListVer` bump is gone too: the script now
  reads the site list already on the machine and increments past it automatically
  whenever the target host changes, which is what Edge's version-based caching requires.
  Change `#define DefaultUrl` in the .iss only if you want a different pre-filled value.

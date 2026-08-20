#Requires -Version 3.0
<#
    Oracle Forms 11g - Enterprise Client Deployment

    Steps:
       1. Remove old Java (5 / 6)
       2. Install the 32-bit JRE 8 shipped alongside this script
       3. Import the SSL certificate chain
       4. Apply Edge IE Mode + Java Control Panel policy, including the
          "Mixed code (sandboxed vs. trusted) security verification" setting
       5. Install Adobe Reader XI silently
       6. Pre-approve the Java browser plug-in (java-plugin-preapprove.reg)
       7. Record the optional branch / lab location codes in the registry
       8. Create the 'LDM' Edge shortcut on the public desktop
       9. Copy the LIS folder tree to C:\LIS
      10. Write the barcode / A4 printer names into AutoPrintFiles.exe.config
      11. Create the 'AutoPrint' desktop shortcut

    Run via Deploy.bat (which enforces elevation). Requires Administrator.
    A full log is written to C:\ProgramData\AppServerClientInstaller\Logs.

    Exit codes: 0 = success, 1 = one or more steps failed, 5 = not elevated,
                6 = the -FormsUrl value is not a usable URL.
#>
param(
    # MANDATORY in effect - the full application URL. Drives EVERY step: the Edge IE
    # Mode site list, the Trusted Sites zone entry, the Java exception site list and
    # both desktop launchers. The default is the previously hardcoded value, so
    # Deploy.bat keeps working with no arguments.
    [string] $FormsUrl = "https://100.74.53.100/forms/frmservlet?config=LDM",

    # Optional numeric location codes. Blank means "leave the registry untouched".
    # Written as REG_SZ under HKLM\SOFTWARE\WOW6432Node\{branch_code,lab_location}.
    [string] $BranchCode = "",
    [string] $LabCode    = "",

    # Unattended mode: no spinner animation, no "press any key" at the end.
    # Set automatically by the installer when it runs /SILENT or /VERYSILENT.
    [switch] $Silent,

    # Extra folder to copy the log and summary into, so a technician can find them
    # next to the installer instead of digging through ProgramData. Ignored if it
    # is not writable (a read-only share or CD, for example).
    [string] $LogCopyDir = "",

    # Optional printer names written into C:\LIS\app\AutoPrintFiles.exe.config
    # (keys "BarcodPrinter" and "A4Printer" - the first is spelled without the
    # trailing 'e' in the shipped config, and that spelling is what AutoPrintFiles
    # actually reads, so it is preserved deliberately).
    # Blank means "leave whatever value the config already holds", which is what
    # makes these safe to omit when only one of the two printers is being changed.
    [string] $BarcodePrinter = "",
    [string] $A4Printer      = "",

    # Step 9 only overwrites an existing C:\LIS when this is passed. The installer
    # asks the technician and sets it accordingly; on a silent run the caller must
    # opt in explicitly, so unattended deployments can never clobber the Backup,
    # Log and back folders of a working till.
    [switch] $LisReplace
)

Start-Sleep -Milliseconds 500
if (-not $Silent) { Clear-Host }
try { $Host.UI.RawUI.WindowTitle = "Oracle Forms 11g - Automated Deployment" } catch { }

# =====================================================================
#  CONFIGURATION - this is the only block you should need to edit
# =====================================================================
# The server is NO LONGER hardcoded here - it is derived from -FormsUrl below, so one
# parameter drives every step. Pass -FormsUrl to retarget a different customer.
$SiteListVerMin = 3               # floor for the IE Mode site list version; the real
                                  # version auto-increments when the site changes
$MinJreUpdate = 241               # reinstall if the installed 8uNNN is older than this
$FallbackDir  = "C:\Java_8_upgrade"   # legacy staging path, still searched
$LogDir       = Join-Path $env:ProgramData "AppServerClientInstaller\Logs"
$StageFromUnc = $true             # copy the package locally first when run from a share

# Legacy TLS. Oracle Forms 11g / OHS 11g typically only offers TLS 1.0 with RSA key
# exchange. Java 8u291 and later refuse that by default via jdk.tls.disabledAlgorithms
# in java.security, and deployment.security.TLSv1=true CANNOT override it - the tokens
# have to physically come out of java.security. These are removed:
#
#   TLSv1, TLSv1.1  - the protocols themselves
#   TLS_RSA_*       - RSA key-exchange suites (e.g. TLS_RSA_WITH_AES_128_CBC_SHA)
#   3DES_EDE_CBC    - 3DES suites, still the only option on some old servers
#
# WARNING: this weakens TLS for EVERY Java application on the machine, not just
# Oracle Forms. Trim this list to the minimum your server actually needs. SSLv3 and
# RC4 are deliberately left disabled - do not add them without a very good reason.
$TlsReEnable  = @('TLSv1', 'TLSv1.1', 'TLS_RSA_*', '3DES_EDE_CBC')
# =====================================================================

# ---------------------------------------------------------------------
#  Everything below is derived from -FormsUrl. $ServerAuthority keeps the port when
#  one is specified (the IE Mode site list and Java exception sites need it), while
#  $ServerHost is the bare host, which is what the Trusted Sites zone range expects.
# ---------------------------------------------------------------------
$FormsUrl = $FormsUrl.Trim()
$UrlError = ""
$uri = $null
try { $uri = [uri]$FormsUrl } catch { $uri = $null }

if (-not $uri -or -not $uri.IsAbsoluteUri) {
    $UrlError = "'$FormsUrl' is not a valid absolute URL."
} elseif (@('http', 'https') -notcontains $uri.Scheme) {
    $UrlError = "URL scheme must be http or https, got '$($uri.Scheme)'."
} elseif (-not $uri.Host) {
    $UrlError = "URL '$FormsUrl' has no host."
}

if ($UrlError) {
    # Fall back to sane values so the script can still start up and report the error
    $ServerHost = ""; $ServerAuthority = ""; $SiteUrl = ""; $FormsConfig = ""
} else {
    $ServerHost      = $uri.Host
    $ServerAuthority = $uri.Authority                                  # host[:port]
    $SiteUrl         = "{0}://{1}" -f $uri.Scheme, $uri.Authority
    $FormsConfig     = ""
    $cfgMatch = [regex]::Match($uri.Query, '(?i)(?:^\?|&)config=([^&]*)')
    if ($cfgMatch.Success) { $FormsConfig = $cfgMatch.Groups[1].Value }
}

# Where this package actually lives. Previously the installer and certificate
# paths were hardcoded to C:\Java_8_upgrade, so running the package from a USB
# stick or a share silently skipped Step 2 and Step 3 entirely.
$SourceDir = $PSScriptRoot
if (-not $SourceDir) { $SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $SourceDir) { $SourceDir = (Get-Location).Path }
$SourceDir = $SourceDir.TrimEnd('\')

# $SearchDirs is built after the banner, because $SourceDir can still change if the
# package needs staging off a network share.
$SearchDirs = @($SourceDir)

$JavaRootDir = ${env:ProgramFiles(x86)}
if (-not $JavaRootDir) { $JavaRootDir = $env:ProgramFiles }
$JavaRootDir = Join-Path $JavaRootDir "Java"

# ---------------------------------------------------------------------
#  Result tracking - the old script always printed "COMPLETED
#  SUCCESSFULLY" regardless of what actually happened.
# ---------------------------------------------------------------------
$script:Failures       = @()
$script:Warnings       = @()
$script:RebootRequired = $false
$script:LastOutput     = ""   # stdout/stderr of the last Invoke-Tracked -Capture call
# Filled in by Steps 4 / 9 / 10 / 11 so the summary file can report what actually
# landed, rather than what was merely requested.
$script:MixcodeApplied = ""
$script:LisCopyResult  = "not reached"
$script:CfgResult      = "not reached"
$script:AutoPrintLnk   = "not reached"

$Interactive = $true
try { $Interactive = -not [Console]::IsOutputRedirected } catch { $Interactive = $false }
# -Silent forces non-interactive: kills both the spinner animation and the final keypress
if ($Silent) { $Interactive = $false }

function Add-Failure { param([string]$Step, [string]$Message) $script:Failures += "[$Step] $Message" }
function Add-Warning { param([string]$Step, [string]$Message) $script:Warnings += "[$Step] $Message" }

function Write-StepTitle { param($Text) Write-Host ""; Write-Host $Text -ForegroundColor Yellow }
function Write-Ok        { param($Text) Write-Host "   -> $Text" -ForegroundColor Green }
function Write-Info      { param($Text) Write-Host "   -> $Text" -ForegroundColor White }
function Write-Skip      { param($Text) Write-Host "   -> SKIPPED: $Text" -ForegroundColor DarkGray }
function Write-Attention { param($Text) Write-Host "   -> WARNING: $Text" -ForegroundColor Yellow }
function Write-Bad       { param($Text) Write-Host "   -> FAILED: $Text" -ForegroundColor Red }

# Echoes a captured child process's output through Write-Host so Start-Transcript
# records it. Blank lines are dropped and long output is capped, to keep the log usable.
function Write-CapturedOutput {
    param(
        [string] $Label,
        [string] $Text,
        [int]    $MaxLines = 40,
        [string] $Colour = "Gray"
    )
    if (-not $Text) { return }
    $lines = @($Text -split "`r?`n" | Where-Object { $_.Trim() -ne "" })
    if ($lines.Count -eq 0) { return }
    Write-Host "      --- $Label ---" -ForegroundColor $Colour
    $shown = $lines
    if ($lines.Count -gt $MaxLines) { $shown = $lines[0..($MaxLines - 1)] }
    foreach ($l in $shown) { Write-Host "      $($l.TrimEnd())" -ForegroundColor $Colour }
    if ($lines.Count -gt $MaxLines) {
        Write-Host "      ... $($lines.Count - $MaxLines) more line(s) suppressed" -ForegroundColor $Colour
    }
}

# Spinner for work with no measurable duration (registry writes, file drops).
function Show-TextSpinner {
    param($Text, $Seconds)
    $spin = @('-', '\', '|', '/')
    $end  = (Get-Date).AddSeconds($Seconds)
    $i    = 0
    Write-Host -NoNewline "   -> $Text  "
    while ((Get-Date) -lt $end) {
        # [Console]::Write bypasses Start-Transcript, keeping the log file readable
        if ($Interactive) { try { [Console]::Write("`b" + $spin[$i % 4]) } catch { } }
        $i++
        Start-Sleep -Milliseconds 150
    }
    if ($Interactive) { try { [Console]::Write("`b") } catch { } }
    Write-Host "[Done]" -ForegroundColor Green
}

# Runs a process and animates only while it is ACTUALLY running, then reports the
# real exit code. The old script animated for a fixed number of seconds and printed
# "[Done]" before the work had even started. Returns $null if it could not launch.
function Invoke-Tracked {
    param(
        [string] $Text,
        [string] $FilePath,
        [string] $Arguments = "",
        [int[]]  $SuccessCodes = @(0),
        # Capture the child's stdout/stderr into $script:LastOutput. Without this the
        # child writes straight to the console, where Start-Transcript CANNOT see it -
        # which is why the IE Mode fix used to leave no trace of what it did in the log.
        [switch] $Capture
    )
    $spin = @('-', '\', '|', '/')
    $script:LastOutput = ""
    Write-Host -NoNewline "   -> $Text  "

    # Built with ProcessStartInfo instead of "Start-Process -PassThru": the latter
    # does not reliably retain the process handle, so $proc.ExitCode reads back as
    # empty once the process has exited - which would make every single step look
    # like a failure. A directly-created Process owns its handle, so ExitCode is
    # valid after exit.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $FilePath
    $psi.Arguments       = $Arguments
    $psi.UseShellExecute = $false
    if ($Capture) {
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
    }

    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-Host "[COULD NOT START]" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
    if (-not $proc) {
        Write-Host "[COULD NOT START]" -ForegroundColor Red
        return $null
    }

    # Start BOTH async reads before waiting. Draining only one pipe - or reading
    # synchronously after the wait - deadlocks as soon as the child fills the other
    # pipe's buffer and blocks on write while we block on exit.
    $outTask = $null
    $errTask = $null
    if ($Capture) {
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
    }

    $i = 0
    while (-not $proc.HasExited) {
        if ($Interactive) { try { [Console]::Write("`b" + $spin[$i % 4]) } catch { } }
        $i++
        Start-Sleep -Milliseconds 150
    }
    $proc.WaitForExit()
    if ($Interactive) { try { [Console]::Write("`b") } catch { } }

    if ($Capture) {
        try {
            $script:LastOutput = (($outTask.Result + "`r`n" + $errTask.Result)).Trim()
        } catch {
            $script:LastOutput = ""
        }
    }

    $code = $proc.ExitCode
    if ($SuccessCodes -contains $code) {
        Write-Host "[Done]" -ForegroundColor Green
    } else {
        Write-Host "[FAILED - exit $code]" -ForegroundColor Red
    }
    if ($code -eq 3010 -or $code -eq 1641) { $script:RebootRequired = $true }
    return $code
}

# Extracts NNN from "jre-8u241-windows-i586.exe" or "jre1.8.0_241"
function Get-JavaUpdateNumber {
    param([string]$Text)
    $m = [regex]::Match($Text, '(?:8u|1\.8\.0_)(\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 0
}

# Finds a shipped file across every search dir. $SourceDir is searched first and
# wins on a filename tie, so a stale copy left behind in the legacy C:\Java_8_upgrade
# folder can never override the file sitting next to this script.
function Find-PackageFiles {
    param([string]$Pattern)
    $found = @()
    $seen  = @{}
    foreach ($dir in $SearchDirs) {
        # -LiteralPath: the folder name is data, so [ ] in a path must not glob
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter $Pattern -File -ErrorAction SilentlyContinue)) {
            if (-not $seen.ContainsKey($f.Name)) {
                $seen[$f.Name] = $true
                $found += $f
            }
        }
    }
    return $found
}

# Newest installed 32-bit JRE 8, sorted by update number. The old script sorted by
# LastWriteTime, so with two JREs present it could pick the older one and then patch
# the wrong java.security file.
function Get-Jre8Dir {
    if (-not (Test-Path -LiteralPath $JavaRootDir)) { return $null }
    $dir = Get-ChildItem -LiteralPath $JavaRootDir -Filter "jre1.8.0*" -Directory -ErrorAction SilentlyContinue |
           Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\java.exe') } |
           Sort-Object { Get-JavaUpdateNumber $_.Name } -Descending |
           Select-Object -First 1
    if ($dir) { return $dir.FullName }
    return $null
}

# Writes a REG_SZ under HKLM using an explicit 64-bit registry view.
#
# Why the explicit view: the installer launches the 32-bit PowerShell (verified -
# Inno's {sys} resolves to SysWOW64), and a 32-bit process has HKLM\SOFTWARE
# redirected to HKLM\SOFTWARE\WOW6432Node. Testing showed Windows does NOT
# re-redirect a path that already names WOW6432Node, so the naive write would in fact
# land correctly - but pinning Registry64 makes the destination unambiguous no matter
# which PowerShell runs this, and keeps working if the path is ever changed to one
# that IS subject to redirection.
function Set-Hklm64String {
    param(
        [string] $SubKey,      # e.g. SOFTWARE\WOW6432Node\branch_code
        [string] $ValueName,
        [string] $Data
    )
    $base = $null
    $key  = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                    [Microsoft.Win32.RegistryHive]::LocalMachine,
                    [Microsoft.Win32.RegistryView]::Registry64)
        # CreateSubKey both creates and opens-for-write, so it covers the
        # "add it" and "update the existing value" cases identically.
        $key = $base.CreateSubKey($SubKey)
        if (-not $key) { throw "CreateSubKey returned nothing for '$SubKey'" }
        $key.SetValue($ValueName, $Data, [Microsoft.Win32.RegistryValueKind]::String)
        return $true
    } catch {
        Write-Bad "Registry write failed for HKLM\$SubKey : $($_.Exception.Message)"
        return $false
    } finally {
        if ($key)  { $key.Close() }
        if ($base) { $base.Close() }
    }
}

# Reads back a REG_SZ from the 64-bit view, so the log can prove what actually landed
function Get-Hklm64String {
    param([string]$SubKey, [string]$ValueName)
    $base = $null; $key = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                    [Microsoft.Win32.RegistryHive]::LocalMachine,
                    [Microsoft.Win32.RegistryView]::Registry64)
        $key = $base.OpenSubKey($SubKey)
        if (-not $key) { return $null }
        return [string]$key.GetValue($ValueName, $null)
    } catch {
        return $null
    } finally {
        if ($key)  { $key.Close() }
        if ($base) { $base.Close() }
    }
}

# Locates msedge.exe: App Paths is authoritative, then the conventional install dirs
function Get-EdgePath {
    $base = $null; $key = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                    [Microsoft.Win32.RegistryHive]::LocalMachine,
                    [Microsoft.Win32.RegistryView]::Registry64)
        $key = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe')
        if ($key) {
            $p = [string]$key.GetValue('', $null)
            if ($p) {
                $p = $p.Trim().Trim('"')
                if (Test-Path -LiteralPath $p) { return $p }
            }
        }
    } catch {
    } finally {
        if ($key)  { $key.Close() }
        if ($base) { $base.Close() }
    }
    foreach ($c in @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
                     "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

# True only for a non-empty string of ASCII digits.
# [0-9] deliberately, NOT \d: in .NET \d matches every Unicode decimal digit, so
# Arabic-Indic numerals (U+0660..U+0669) would pass and then be written to the registry
# as a "numeric" code that nothing downstream can parse. Verified: '\d' accepted them,
# '[0-9]' rejects them. Mirrors the installer's Pascal-side check, which is ASCII too.
function Test-DigitsOnly {
    param([string]$Value)
    if (-not $Value) { return $false }
    return ($Value -match '^[0-9]+$')
}

# Removes tokens from a comma-separated java.security property, following the
# backslash line-continuations that these properties are wrapped across, and rewrites
# the whole property as a single line. Returns the new line array plus what changed.
# Idempotent: removing an already-absent token is a no-op.
function Edit-SecurityListProperty {
    param(
        [string[]] $Lines,
        [string]   $Property,
        [string[]] $RemoveTokens
    )
    $startIdx = -1
    $rx = "^\s*" + [regex]::Escape($Property) + "\s*="
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match $rx) { $startIdx = $i; break }
    }
    if ($startIdx -lt 0) {
        return @{ Lines = $Lines; Found = $false; Removed = @(); Kept = @() }
    }

    # Walk the continuations to assemble the full logical value
    $endIdx = $startIdx
    $parts  = @()
    $first  = $Lines[$startIdx]
    $parts += $first.Substring($first.IndexOf('=') + 1)
    while ($Lines[$endIdx].TrimEnd().EndsWith('\')) {
        $endIdx++
        if ($endIdx -ge $Lines.Count) { $endIdx = $Lines.Count - 1; break }
        $parts += $Lines[$endIdx]
    }
    $parts = $parts | ForEach-Object { $_.TrimEnd().TrimEnd('\').Trim() }
    $flat  = ($parts -join ' ')

    $keep = @(); $removed = @()
    foreach ($t in ($flat -split ',')) {
        $tok = $t.Trim()
        if (-not $tok) { continue }
        # -contains is case-insensitive for strings, and does NOT treat * as a wildcard
        if ($RemoveTokens -contains $tok) { $removed += $tok } else { $keep += $tok }
    }

    $out = @()
    if ($startIdx -gt 0) { $out += $Lines[0..($startIdx - 1)] }
    $out += ($Property + "=" + ($keep -join ', '))
    if (($endIdx + 1) -lt $Lines.Count) { $out += $Lines[($endIdx + 1)..($Lines.Count - 1)] }

    return @{ Lines = $out; Found = $true; Removed = $removed; Kept = $keep }
}

# ---------------------------------------------------------------------
#  Logging
# ---------------------------------------------------------------------
$LogFile = $null
try {
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
    $stamp   = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $LogFile = Join-Path $LogDir ("deploy_{0}_{1}.log" -f $env:COMPUTERNAME, $stamp)
    Start-Transcript -Path $LogFile -Force | Out-Null
} catch {
    $LogFile = $null
}

Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "     Oracle Forms 11g - Enterprise Deployment Script   " -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "  URL      : $FormsUrl"
Write-Host "  Server   : $ServerAuthority$(if ($FormsConfig) { " (config=$FormsConfig)" })"
Write-Host "  Branch   : $(if ($BranchCode) { $BranchCode } else { '(not supplied)' })"
Write-Host "  Lab      : $(if ($LabCode)    { $LabCode }    else { '(not supplied)' })"
Write-Host "  Package  : $SourceDir"
if ($LogFile) { Write-Host "  Log      : $LogFile" }
else          { Write-Host "  Log      : (could not be created)" -ForegroundColor Yellow }
Write-Host ""

# ---------------------------------------------------------------------
#  Elevation. Deploy.bat already gates on this, but the script can also be
#  launched directly - failing 13 steps in a row is a terrible way to find out.
# ---------------------------------------------------------------------
$isAdmin = $false
try {
    $wp = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }
if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "       - launched from the Setup .exe: approve the elevation prompt." -ForegroundColor Red
    Write-Host "       - launched from Deploy.bat: right-click it, 'Run as administrator'." -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch { }
    if ($Interactive) {
        Write-Host ""
        Write-Host "Press any key to exit..."
        try { $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null } catch { }
    }
    exit 5
}

# ---------------------------------------------------------------------
#  The URL drives every step, so an invalid one must stop here rather than half
#  configure the machine against a broken address.
# ---------------------------------------------------------------------
if ($UrlError) {
    Write-Host "ERROR: $UrlError" -ForegroundColor Red
    Write-Host "       Pass a full URL, e.g. -FormsUrl ""https://host/forms/frmservlet?config=LDM""" -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch { }
    if ($Interactive) {
        Write-Host ""
        Write-Host "Press any key to exit..."
        try { $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null } catch { }
    }
    exit 6
}

# ---------------------------------------------------------------------
#  Package location. The script runs from wherever it happens to live; running
#  installers straight off a UNC share is unreliable (zone blocking, slow reads),
#  so stage locally in that one case. Local paths, USB included, run in place.
# ---------------------------------------------------------------------
if ($StageFromUnc -and $SourceDir.StartsWith('\\')) {
    $stageDir = Join-Path $env:TEMP "AppServerClientInstaller_stage"
    Write-Info "Package is on a network share. Staging locally to $stageDir"
    try {
        if (-not (Test-Path -LiteralPath $stageDir)) {
            New-Item -ItemType Directory -Force -Path $stageDir | Out-Null
        }
        Get-ChildItem -LiteralPath $SourceDir -File -ErrorAction Stop |
            Copy-Item -Destination $stageDir -Force -ErrorAction Stop
        $SourceDir = $stageDir.TrimEnd('\')
        Write-Ok "Staged locally, running from $SourceDir"
    } catch {
        Write-Attention "Local staging failed, continuing from the share: $($_.Exception.Message)"
        Add-Warning "Setup" "UNC staging failed - ran directly from the network share"
    }
}

$SearchDirs = @($SourceDir)
if ((Test-Path -LiteralPath $FallbackDir) -and ($FallbackDir.TrimEnd('\') -ine $SourceDir.TrimEnd('\'))) {
    $SearchDirs += $FallbackDir.TrimEnd('\')
}
Write-Host "  Searching: $($SearchDirs -join '  |  ')"
Write-Host ""

# =====================================================================
# STEP 1: Uninstall old Java
# =====================================================================
Write-Host "[Step 1] Checking and enforcing removal of all old Java versions..." -ForegroundColor Yellow

$java6Found = $true
$loopCount  = 0

while ($java6Found -and $loopCount -lt 5) {
    $loopCount++
    $java6Apps = @()

    $uninstallKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    foreach ($key in $uninstallKeys) {
        if (Test-Path $key) {
            $subKeys = Get-ChildItem -Path $key -ErrorAction SilentlyContinue
            foreach ($sub in $subKeys) {
                $app = Get-ItemProperty -Path $sub.PSPath -ErrorAction SilentlyContinue
                if ($app -and $app.DisplayName) {
                    if ($app.DisplayName -match "Java\(TM\) SE Development Kit 6" -or $app.DisplayName -match "Java\(TM\) 6" -or $app.DisplayName -match "Java 6" -or $app.DisplayName -match "J2SE Runtime Environment 6" -or $app.DisplayName -match "J2SE Runtime Environment 5") {
                        $java6Apps += $app
                    }
                }
            }
        }
    }

    if ($java6Apps.Count -eq 0 -and $loopCount -eq 1) {
        Show-TextSpinner -Text "Deep scanning WMI for hidden versions..." -Seconds 2
        $wmiApps = Get-WmiObject -Class Win32_Product -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "Java\(TM\) SE Development Kit 6" -or $_.Name -match "Java\(TM\) 6" -or $_.Name -match "Java 6" }
        if ($wmiApps) {
            foreach ($w in $wmiApps) {
                $fakeApp = New-Object PSObject -Property @{ DisplayName = $w.Name; UninstallString = ""; PSChildName = $w.IdentifyingNumber }
                $java6Apps += $fakeApp
            }
        }
    }

    if ($java6Apps.Count -gt 0) {
        foreach ($app in $java6Apps) {
            Write-Info "Found old version: $($app.DisplayName)"

            if ($app.PSChildName -match "^\{.*\}$") {
                $guid = $app.PSChildName
                # 1605 = product not installed (already gone), 3010/1641 = reboot needed
                $okCodes = @(0, 1605, 3010, 1641)
                $code = Invoke-Tracked -Text "Uninstalling $($app.DisplayName)..." `
                                       -FilePath "msiexec.exe" `
                                       -Arguments "/x `"$guid`" /qn /norestart" `
                                       -SuccessCodes $okCodes
                if ($null -eq $code -or $okCodes -notcontains $code) {
                    Add-Failure "Step 1" "Could not uninstall $($app.DisplayName) (msiexec exit $code)"
                }
            } else {
                Write-Info "Uninstalling $($app.DisplayName) via WMI..."
                $prod = Get-WmiObject -Class Win32_Product -Filter "Name='$($app.DisplayName)'" -ErrorAction SilentlyContinue
                if ($prod) {
                    $result = $prod.Uninstall()
                    if ($result.ReturnValue -eq 0) {
                        Write-Ok "Removed $($app.DisplayName)"
                    } else {
                        Write-Bad "WMI uninstall returned $($result.ReturnValue)"
                        Add-Failure "Step 1" "WMI uninstall of $($app.DisplayName) returned $($result.ReturnValue)"
                    }
                } else {
                    Write-Bad "No uninstall method found for $($app.DisplayName)"
                    Add-Failure "Step 1" "No uninstall method found for $($app.DisplayName)"
                }
            }
        }
        Show-TextSpinner -Text "Re-scanning system for leftovers..." -Seconds 2
    } else {
        $java6Found = $false
        Write-Ok "VERIFIED: No Java 6 versions found. System is 100% clean!"
    }
}

# The old script gave up silently after 5 passes.
if ($java6Found) {
    Write-Attention "Old Java is STILL present after $loopCount removal passes."
    Add-Failure "Step 1" "Old Java still present after $loopCount passes - remove it manually"
}

# =====================================================================
# STEP 2: Install Java 8
# =====================================================================
Write-StepTitle "[Step 2] Checking for Java 8 Installation..."

# Filename is no longer hardcoded - any jre-8u*-windows-i586.exe in the package works
$jreInstaller = Find-PackageFiles -Pattern "jre-8u*-windows-i586.exe" |
                Sort-Object { Get-JavaUpdateNumber $_.Name } -Descending |
                Select-Object -First 1

$shippedUpdate  = 0
$requiredUpdate = $MinJreUpdate
if ($jreInstaller) {
    $shippedUpdate = Get-JavaUpdateNumber $jreInstaller.Name
    if ($shippedUpdate -gt $requiredUpdate) { $requiredUpdate = $shippedUpdate }
}

# Check java.exe physically exists, to avoid false positives from broken uninstalls
$installedDir    = Get-Jre8Dir
$installedUpdate = 0
if ($installedDir) { $installedUpdate = Get-JavaUpdateNumber $installedDir }

if ($installedDir -and $installedUpdate -ge $requiredUpdate) {
    Write-Ok "SKIPPED: Java 8u$installedUpdate is already installed ($installedDir)"
} else {
    if ($installedDir) {
        Write-Info "Found Java 8u$installedUpdate, but 8u$requiredUpdate is required. Upgrading..."
    }
    if ($jreInstaller) {
        Write-Info "Using installer: $($jreInstaller.FullName)"
        $okCodes = @(0, 3010, 1641)
        # Report the version actually being installed, not $requiredUpdate - those
        # differ if $MinJreUpdate is ever raised above the installer in the package.
        $code = Invoke-Tracked -Text "Installing Java 8u$shippedUpdate (this takes a few minutes)..." `
                               -FilePath $jreInstaller.FullName `
                               -Arguments "/s REBOOT=0 AUTO_UPDATE=0 WEB_JAVA=1 WEB_ANALYTICS=0" `
                               -SuccessCodes $okCodes
        $installedDir    = Get-Jre8Dir
        $installedUpdate = 0
        if ($installedDir) { $installedUpdate = Get-JavaUpdateNumber $installedDir }

        if (-not $installedDir) {
            Write-Bad "Installer finished (exit $code) but no working JRE 8 was found."
            Add-Failure "Step 2" "JRE 8 install did not produce a usable JRE (exit $code)"
        } elseif ($installedUpdate -lt $requiredUpdate) {
            Write-Attention "Installed 8u$installedUpdate but MinJreUpdate demands 8u$requiredUpdate."
            Add-Failure "Step 2" "Package ships 8u$shippedUpdate but MinJreUpdate is $requiredUpdate - ship a newer JRE or lower MinJreUpdate"
        } else {
            Write-Ok "Java 8u$installedUpdate installed: $installedDir"
        }
    } else {
        Write-Bad "Java 8 installer (jre-8u*-windows-i586.exe) not found in:"
        foreach ($d in $SearchDirs) { Write-Host "        $d" -ForegroundColor Red }
        Add-Failure "Step 2" "jre-8u*-windows-i586.exe missing from the package"
    }
}

# =====================================================================
# STEP 3: Install SSL Certificates
# =====================================================================
Write-StepTitle "[Step 3] Installing SSL Certificates to Trusted Root..."

# Same first-wins rule as Find-PackageFiles: a cert next to this script beats a
# same-named stale copy in the legacy C:\Java_8_upgrade folder.
$certs = @()
$seenCerts = @{}
foreach ($dir in $SearchDirs) {
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Extension -match "^\.(cer|crt|der|pem)$" })) {
        if (-not $seenCerts.ContainsKey($f.Name)) {
            $seenCerts[$f.Name] = $true
            $certs += $f
        }
    }
}

if ($certs.Count -gt 0) {
    foreach ($cert in $certs) {
        $code = Invoke-Tracked -Text "Installing Certificate: $($cert.Name)..." `
                               -FilePath "certutil.exe" `
                               -Arguments "-addstore -f `"Root`" `"$($cert.FullName)`"" `
                               -Capture
        if ($code -eq 0) {
            Write-Ok "Certificate $($cert.Name) installed successfully!"
        } else {
            # Only on failure - certutil is verbose and would bury the log on success
            Write-CapturedOutput -Label "certutil output" -Text $script:LastOutput -Colour "Red"
            Add-Failure "Step 3" "certutil failed on $($cert.Name) (exit $code)"
        }
    }
} else {
    Write-Bad "No certificate files (*.cer, *.crt, *.der, *.pem) found in:"
    foreach ($d in $SearchDirs) { Write-Host "        $d" -ForegroundColor Red }
    Add-Failure "Step 3" "No certificate files found in the package"
}

# =====================================================================
# STEP 4: Apply Fixes
# =====================================================================
Write-StepTitle "[Step 4] Applying Deep System Fixes..."

Show-TextSpinner -Text "Applying Edge IE Mode Policies & Trusted Sites..." -Seconds 2

# Disable IE-to-Edge Redirection
reg add "HKLM\SOFTWARE\Policies\Microsoft\Edge" /v RedirectSitesFromInternetExplorerRedirectMode /t REG_DWORD /d 0 /f > $null

# Enable IE Mode in Edge and allow reload
reg add "HKLM\SOFTWARE\Policies\Microsoft\Edge" /v InternetExplorerIntegrationLevel /t REG_DWORD /d 1 /f > $null
reg add "HKLM\SOFTWARE\Policies\Microsoft\Edge" /v InternetExplorerIntegrationReloadInIEModeAllowed /t REG_DWORD /d 1 /f > $null

# Create Edge Enterprise Mode Site List for Permanent IE Mode
$sysDeployDir = "C:\Windows\Sun\Java\Deployment"
if (!(Test-Path $sysDeployDir)) { New-Item -ItemType Directory -Force -Path $sysDeployDir | Out-Null }
$siteListXml = "$sysDeployDir\edge_iemode_list.xml"

# Edge caches the Enterprise Mode site list BY VERSION NUMBER: if the file changes but
# the version does not increase, machines that already read an older copy keep using it.
# Now that the URL is user-supplied this cannot be a hand-maintained constant, so the
# version is derived - bumped past whatever is already on disk whenever the site
# actually differs, and left alone when it does not.
$SiteListVer = $SiteListVerMin
if (Test-Path -LiteralPath $siteListXml) {
    $oldXml = ""
    try { $oldXml = [System.IO.File]::ReadAllText($siteListXml) } catch { }
    $oldVer  = 0
    $oldSite = ""
    $m = [regex]::Match($oldXml, 'version="(\d+)"')
    if ($m.Success) { $oldVer = [int]$m.Groups[1].Value }
    $m = [regex]::Match($oldXml, '<site\s+url="([^"]*)"')
    if ($m.Success) { $oldSite = $m.Groups[1].Value }

    if ($oldSite -ieq $ServerAuthority) {
        $SiteListVer = [Math]::Max($oldVer, $SiteListVerMin)
        Write-Info "IE Mode site list already targets $ServerAuthority (version $SiteListVer)."
    } else {
        $SiteListVer = [Math]::Max($oldVer + 1, $SiteListVerMin)
        Write-Info "IE Mode site list changing '$oldSite' -> '$ServerAuthority', version $oldVer -> $SiteListVer."
    }
}

$xmlContent = @"
<site-list version="$SiteListVer">
  <site url="$ServerAuthority">
    <compat-mode>Default</compat-mode>
    <open-in>IE11</open-in>
  </site>
</site-list>
"@
$xmlContent | Out-File $siteListXml -Encoding ASCII
$siteListUrl = "file:///" + ($siteListXml -replace '\\', '/')
reg add "HKLM\SOFTWARE\Policies\Microsoft\Edge" /v InternetExplorerIntegrationSiteList /t REG_SZ /d "$siteListUrl" /f > $null

# Trusted Sites (Zone 2)
reg add "HKLM\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Ranges\RangeTrusted" /v ":Range" /t REG_SZ /d "$ServerHost" /f > $null
reg add "HKLM\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Ranges\RangeTrusted" /v "https" /t REG_DWORD /d 2 /f > $null

# Disable Java Auto Update
reg add "HKLM\SOFTWARE\JavaSoft\Java Update\Policy" /v EnableJavaUpdate /t REG_DWORD /d 0 /f > $null
reg add "HKLM\SOFTWARE\WOW6432Node\JavaSoft\Java Update\Policy" /v EnableJavaUpdate /t REG_DWORD /d 0 /f > $null

Show-TextSpinner -Text "Configuring Java Settings (Control Panel)..." -Seconds 2
$mandatoryConfig = "deployment.system.config=file\:C\:/Windows/Sun/Java/Deployment/deployment.properties`r`ndeployment.system.config.mandatory=true"
[System.IO.File]::WriteAllText("$sysDeployDir\deployment.config", $mandatoryConfig)

# Set properties without locking them, allowing manual override.
#
# deployment.security.mixcode drives Java Control Panel > Advanced > "Mixed code
# (sandboxed vs. trusted) security verification". Java accepts exactly four values,
# confirmed against the MIXCODE_MODE_* constants in com.sun.deploy.config.Config
# inside deploy.jar:
#
#   ENABLE      -> "Enable - show warning if needed"                    (Java default)
#   HIDE_RUN    -> "Enable - hide warning and run with protections"
#   HIDE_CANCEL -> "Enable - hide warning and don't run untrusted code" <-- required
#   DISABLE     -> "Disable verification (not recommended)"
#
# Anything else is silently discarded and Java falls back to ENABLE, i.e. the mixed
# code warning keeps appearing. Earlier versions of this script wrote HIDE_UNTRUSTED,
# which is not one of the four, so the setting never actually took effect on a client.
# Do not "tidy" this value.
$props = "deployment.security.level=HIGH`r`ndeployment.security.mixcode=HIDE_CANCEL`r`ndeployment.security.revocation.check=NO_CHECK`r`ndeployment.security.tls.revocation.check=NO_CHECK`r`ndeployment.security.validation.crl=false`r`ndeployment.security.validation.ocsp=false`r`ndeployment.security.TLSv1=true`r`ndeployment.security.TLSv1.1=true`r`ndeployment.javaws.jre.0.args=-Dsun.java2d.noddraw=true -Dsun.java2d.d3d=false`r`ndeployment.user.security.exception.sites=C:/Windows/Sun/Java/Deployment/security/exception.sites`r`ndeployment.expiration.check.enabled=false`r`ndeployment.javaws.autodownload=NEVER"
[System.IO.File]::WriteAllText("$sysDeployDir\deployment.properties", $props)

# Read the mixed-code setting back out of the file that Java will actually load, rather
# than trusting the write. This is the one Control Panel setting the customer asked to
# be able to confirm, so it gets its own line in the log instead of being buried.
$mixWanted = "HIDE_CANCEL"
$mixActual = $null
try {
    $mixLine = Get-Content -LiteralPath "$sysDeployDir\deployment.properties" -ErrorAction Stop |
               Where-Object { $_ -match '^\s*deployment\.security\.mixcode\s*=' } |
               Select-Object -Last 1
    if ($mixLine) { $mixActual = ($mixLine -split '=', 2)[1].Trim() }
} catch { $mixActual = $null }

$script:MixcodeApplied = $mixActual
if ($mixActual -eq $mixWanted) {
    Write-Ok "Mixed code security verification = $mixActual (Enable - hide warning and don't run untrusted code)"
} else {
    Write-Bad "Mixed code security verification is '$mixActual', expected '$mixWanted'."
    Add-Failure "Step 4" "deployment.security.mixcode read back as '$mixActual' instead of '$mixWanted'"
}

# Drop system config into the JRE lib folder as the ultimate override (but not mandatory)
$jreLibConfig = "deployment.system.config=file\:C\:/Windows/Sun/Java/Deployment/deployment.properties"
$javaDir = Get-Jre8Dir
if ($javaDir) {
    [System.IO.File]::WriteAllText("$javaDir\lib\deployment.config", $jreLibConfig)
    [System.IO.File]::WriteAllText("$javaDir\lib\deployment.properties", $props)
} else {
    Write-Attention "No JRE 8 found - JRE-level deployment config was not written."
    Add-Warning "Step 4" "JRE-level deployment config skipped (no JRE 8 present)"
}

$securityDir = "$sysDeployDir\security"
if (!(Test-Path $securityDir)) { New-Item -ItemType Directory -Force -Path $securityDir | Out-Null }
[System.IO.File]::WriteAllText("$securityDir\exception.sites", $SiteUrl)

# Force properties to all existing user profiles to ensure Control Panel recognizes it
$users = Get-ChildItem -Path "C:\Users" -Directory
foreach ($user in $users) {
    $userDeployDir = "$($user.FullName)\AppData\LocalLow\Sun\Java\Deployment"
    if (Test-Path "$($user.FullName)\AppData\LocalLow") {
        if (!(Test-Path $userDeployDir)) { New-Item -ItemType Directory -Force -Path $userDeployDir | Out-Null }
        [System.IO.File]::WriteAllText("$userDeployDir\deployment.properties", $props)

        $userSecDir = "$userDeployDir\security"
        if (!(Test-Path $userSecDir)) { New-Item -ItemType Directory -Force -Path $userSecDir | Out-Null }
        [System.IO.File]::WriteAllText("$userSecDir\exception.sites", $SiteUrl)
    }
}

Show-TextSpinner -Text "Patching Java Security (MD5/SHA1 + legacy TLS)..." -Seconds 1
$javaDir = Get-Jre8Dir
if ($javaDir) {
    $securityFile = "$javaDir\lib\security\java.security"
    if (Test-Path -LiteralPath $securityFile) {

        # Keep one pristine copy. Never overwrite an existing .bak, so re-running this
        # script can't destroy the original after the first patch.
        $backupFile = "$securityFile.original.bak"
        if (-not (Test-Path -LiteralPath $backupFile)) {
            try {
                Copy-Item -LiteralPath $securityFile -Destination $backupFile -Force -ErrorAction Stop
                Write-Info "Backed up original java.security -> $(Split-Path -Leaf $backupFile)"
            } catch {
                Write-Attention "Could not back up java.security: $($_.Exception.Message)"
                Add-Warning "Step 4" "java.security backup failed"
            }
        }

        $content = Get-Content -LiteralPath $securityFile
        $content = $content -replace 'MD5, ', '' -replace 'MD2, ', ''
        $content = $content -replace '& denyAfter \d{4}-\d{2}-\d{2}', ''
        $content = $content -replace 'RSA keySize < \d+', 'RSA keySize < 512'

        # Re-enable the legacy TLS protocols and ciphers that Forms 11g needs. This is
        # the only place it can be done - deployment.security.TLSv1=true does not
        # override jdk.tls.disabledAlgorithms.
        $tls = Edit-SecurityListProperty -Lines $content -Property 'jdk.tls.disabledAlgorithms' -RemoveTokens $TlsReEnable
        $content = $tls.Lines
        if ($tls.Found) {
            if ($tls.Removed.Count -gt 0) {
                Write-Ok "Legacy TLS re-enabled (removed: $($tls.Removed -join ', '))"
            } else {
                Write-Info "Legacy TLS already enabled - nothing to remove."
            }
        } else {
            Write-Attention "jdk.tls.disabledAlgorithms not found - this JRE predates it."
        }

        Set-Content -LiteralPath $securityFile -Value $content -Encoding ASCII

        # An explicit jdk.tls.client.protocols would silently override all of the above
        $clientProto = @($content | Where-Object { $_ -match '^\s*jdk\.tls\.client\.protocols\s*=' })
        if ($clientProto.Count -gt 0) {
            Write-Attention "jdk.tls.client.protocols is set and may override the fix: $($clientProto[0].Trim())"
            Add-Warning "Step 4" "jdk.tls.client.protocols is set: $($clientProto[0].Trim())"
        }
    } else {
        Write-Attention "java.security not found at $securityFile"
        Add-Warning "Step 4" "java.security not found - algorithm and TLS patch skipped"
    }
} else {
    Add-Warning "Step 4" "No JRE 8 present - java.security patch skipped"
}

Show-TextSpinner -Text "Creating Desktop Launcher..." -Seconds 1
$vbsPath = "$env:PUBLIC\Desktop\Launch_Oracle_Forms.vbs"
$vbsCode = 'Set ie = CreateObject("InternetExplorer.Application") : ie.Visible = True : ie.Navigate "{0}"' -f $FormsUrl
$vbsCode | Out-File $vbsPath -Encoding ASCII

# IE Mode expiry fix. Driven by a generated INI file so the third-party VBS stays
# unmodified. Critically: it is run with CScript, which suppresses the two MsgBox
# dialogs that used to block the whole deployment waiting for a human to click OK.
# AllUsers=1 is required because %UserProfile% under elevation resolves to the
# ADMIN's profile, not the logged-in user's.
$ieFixFile = Join-Path $SourceDir "IEModeExpiryFix.vbs"
if (Test-Path -LiteralPath $ieFixFile) {
    Write-Attention "Microsoft Edge will be closed now (the IE Mode fix requires it)."
    $iniPath = Join-Path $env:TEMP "IEModeExpiryFix.ini"
    # NOTE: this INI parser ignores any line containing more than one "=", so the
    # AddPages URL must not carry ?config=... (the VBS trims at "?" anyway).
    $iniBody = @"
[Options]
Silent=0
AllUsers=1
RemoveAll=0
Backup=1

[Content]
DateAdded=10/28/2099 10:00:00 PM
AddPages=$SiteUrl/forms/frmservlet
"@
    [System.IO.File]::WriteAllText($iniPath, $iniBody)

    $code = Invoke-Tracked -Text "Applying IE Mode Expiry Fix (all profiles)..." `
                           -FilePath "cscript.exe" `
                           -Arguments "//nologo `"$ieFixFile`" `"$iniPath`"" `
                           -Capture
    # ALWAYS surface this one. It reports which Edge profiles it touched and whether a
    # signed-in profile blocked the edit - the difference between "worked" and "silently
    # did nothing", which the log previously could not distinguish.
    Write-CapturedOutput -Label "IEModeExpiryFix.vbs report" -Text $script:LastOutput -Colour "Gray"
    if ($code -ne 0) { Add-Warning "Step 4" "IEModeExpiryFix.vbs exited with $code" }
    if ($script:LastOutput -match 'sign-in detected') {
        Write-Attention "At least one Edge profile is signed in - IE Mode entries there could not be updated."
        Add-Warning "Step 4" "An Edge profile is signed in; its IE Mode entries were not updated"
    }
    if (-not $script:LastOutput) {
        Write-Attention "The IE Mode fix produced no output - it may not have found any Edge profile."
        Add-Warning "Step 4" "IEModeExpiryFix.vbs produced no output (no Edge profile found?)"
    }
} else {
    Write-Skip "IEModeExpiryFix.vbs not found in $SourceDir"
    Add-Warning "Step 4" "IEModeExpiryFix.vbs missing from the package"
}

# =====================================================================
# STEP 5: Install Adobe Reader XI
# =====================================================================
Write-StepTitle "[Step 5] Checking for Adobe Reader..."

$existingReader = $null
foreach ($key in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
                   "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall")) {
    if (Test-Path $key) {
        foreach ($sub in (Get-ChildItem -Path $key -ErrorAction SilentlyContinue)) {
            $app = Get-ItemProperty -Path $sub.PSPath -ErrorAction SilentlyContinue
            # Matches Reader XI, Reader DC AND full Acrobat, so a machine that already
            # has Acrobat is not cluttered with a Reader XI install. Deliberately does
            # not match satellite entries like "Adobe Refresh Manager" or "Adobe AIR",
            # which would otherwise block the install.
            if ($app -and $app.DisplayName -match "Adobe (Acrobat|Reader)") {
                $existingReader = $app.DisplayName
                break
            }
        }
    }
    if ($existingReader) { break }
}

if ($existingReader) {
    # Do not reinstall, and do not downgrade a newer Reader DC back to XI
    Write-Ok "SKIPPED: '$existingReader' is already installed."
} else {
    $adobeInstaller = Find-PackageFiles -Pattern "AdbeRdr*.exe" |
                      Sort-Object Name -Descending | Select-Object -First 1
    if ($adobeInstaller) {
        Write-Info "Using installer: $($adobeInstaller.FullName)"
        # Adobe Self Extractor switches: /sAll = silent for all, /rs = suppress reboot,
        # /msi passes the remaining properties through to the MSI.
        $okCodes = @(0, 3010, 1641)
        $code = Invoke-Tracked -Text "Installing Adobe Reader silently (this takes a few minutes)..." `
                               -FilePath $adobeInstaller.FullName `
                               -Arguments "/sAll /rs /msi EULA_ACCEPT=YES" `
                               -SuccessCodes $okCodes
        if ($null -ne $code -and $okCodes -contains $code) {
            Write-Ok "Adobe Reader installed successfully!"
        } else {
            Add-Failure "Step 5" "Adobe Reader install failed (exit $code)"
        }
    } else {
        Write-Bad "Adobe Reader installer (AdbeRdr*.exe) not found in:"
        foreach ($d in $SearchDirs) { Write-Host "        $d" -ForegroundColor Red }
        Add-Failure "Step 5" "AdbeRdr*.exe missing from the package"
    }
}

# =====================================================================
# STEP 6: Pre-approve the Java browser plug-in  (must run last)
# =====================================================================
Write-StepTitle "[Step 6] Pre-approving the Java browser plug-in..."

$regFile = Find-PackageFiles -Pattern "java-plugin-preapprove.reg" | Select-Object -First 1
if ($regFile) {
    Write-Info "Importing: $($regFile.FullName)"
    $code = Invoke-Tracked -Text "Running reg import (as Administrator)..." `
                           -FilePath "reg.exe" `
                           -Arguments "import `"$($regFile.FullName)`"" `
                           -Capture
    if ($code -eq 0) {
        Write-Ok "Java plug-in pre-approved (64-bit and Wow6432Node views)."
    } else {
        Write-CapturedOutput -Label "reg output" -Text $script:LastOutput -Colour "Red"
        Add-Failure "Step 6" "reg import of $($regFile.Name) failed (exit $code)"
    }
} else {
    Write-Bad "java-plugin-preapprove.reg not found in:"
    foreach ($d in $SearchDirs) { Write-Host "        $d" -ForegroundColor Red }
    Add-Failure "Step 6" "java-plugin-preapprove.reg missing from the package"
}

# =====================================================================
# STEP 7: Location codes (optional)
# =====================================================================
Write-StepTitle "[Step 7] Recording location codes..."

# Key path, value name and value data all use the same identifier, per spec:
#   HKLM\SOFTWARE\WOW6432Node\branch_code   value "branch_code"   = <digits>
#   HKLM\SOFTWARE\WOW6432Node\lab_location  value "lab_location"  = <digits>
$codeTargets = @(
    @{ Label = "Branch location code"; Value = $BranchCode; Key = "SOFTWARE\WOW6432Node\branch_code";  Name = "branch_code"  },
    @{ Label = "Lab location code";    Value = $LabCode;    Key = "SOFTWARE\WOW6432Node\lab_location"; Name = "lab_location" }
)

$anyCode = $false
foreach ($t in $codeTargets) {
    if (-not $t.Value) { continue }
    $anyCode = $true

    if (-not (Test-DigitsOnly $t.Value)) {
        Write-Bad "$($t.Label) '$($t.Value)' is not digits only - registry NOT written."
        Add-Failure "Step 7" "$($t.Label) '$($t.Value)' is not numeric; $($t.Name) was not written"
        continue
    }

    $existing = Get-Hklm64String -SubKey $t.Key -ValueName $t.Name
    if (Set-Hklm64String -SubKey $t.Key -ValueName $t.Name -Data $t.Value) {
        # Read back rather than trust the write, so the log records what actually landed
        $now = Get-Hklm64String -SubKey $t.Key -ValueName $t.Name
        if ($now -eq $t.Value) {
            if ($null -eq $existing) {
                Write-Ok "$($t.Label): created HKLM\$($t.Key) -> $($t.Name) = $now"
            } elseif ($existing -eq $t.Value) {
                Write-Ok "$($t.Label): already $now, unchanged."
            } else {
                Write-Ok "$($t.Label): updated $($t.Name) from '$existing' to '$now'"
            }
        } else {
            Write-Bad "$($t.Label): wrote '$($t.Value)' but read back '$now'"
            Add-Failure "Step 7" "$($t.Name) read back as '$now' instead of '$($t.Value)'"
        }
    } else {
        Add-Failure "Step 7" "Could not write $($t.Name) to HKLM\$($t.Key)"
    }
}

if (-not $anyCode) {
    Write-Skip "No branch or lab code supplied - registry left unchanged."
}

# =====================================================================
# STEP 8: Desktop shortcut  (runs last, after everything is configured)
# =====================================================================
Write-StepTitle "[Step 8] Creating the 'LDM' Edge shortcut on the desktop..."

$edgeExe = Get-EdgePath
if (-not $edgeExe) {
    Write-Bad "msedge.exe not found - the LDM shortcut was not created."
    Add-Failure "Step 8" "Microsoft Edge not found; LDM desktop shortcut not created"
} else {
    Write-Info "Edge: $edgeExe"
    # Public Desktop so every user of the machine gets it, matching the existing launcher
    $desktopDir = Join-Path $env:PUBLIC "Desktop"
    $lnkPath    = Join-Path $desktopDir "LDM.lnk"
    $shell      = $null
    try {
        if (-not (Test-Path -LiteralPath $desktopDir)) {
            New-Item -ItemType Directory -Force -Path $desktopDir -ErrorAction Stop | Out-Null
        }
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut($lnkPath)
        $sc.TargetPath       = $edgeExe
        # Quoted so a URL containing a space or & cannot be split by the shell.
        # No IE Mode switch is needed: the Enterprise Mode site list written in Step 4
        # makes Edge open this address in IE Mode automatically.
        $sc.Arguments        = '"' + $FormsUrl + '"'
        $sc.WorkingDirectory = Split-Path -Parent $edgeExe
        $sc.IconLocation     = "$edgeExe,0"
        $sc.Description      = "Oracle Forms 11g - LDM"
        $sc.Save()

        if (Test-Path -LiteralPath $lnkPath) {
            Write-Ok "Created: $lnkPath"
            Write-Info "Opens: $FormsUrl"
        } else {
            Write-Bad "Save() reported no error but $lnkPath does not exist."
            Add-Failure "Step 8" "LDM shortcut was not created at $lnkPath"
        }
    } catch {
        Write-Bad "Could not create the LDM shortcut: $($_.Exception.Message)"
        Add-Failure "Step 8" "LDM desktop shortcut failed: $($_.Exception.Message)"
    } finally {
        if ($shell) {
            try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null } catch { }
        }
    }
}

# =====================================================================
# STEP 9: Copy the LIS folder tree to C:\LIS
# =====================================================================
Write-StepTitle "[Step 9] Deploying the LIS folder to C:\LIS..."

$LisDest = "C:\LIS"
$lisSrc  = $null
foreach ($dir in $SearchDirs) {
    $candidate = Join-Path $dir "LIS"
    if (Test-Path -LiteralPath $candidate -PathType Container) { $lisSrc = $candidate; break }
}

if (-not $lisSrc) {
    Write-Bad "No 'LIS' folder found in the package - nothing to copy."
    foreach ($d in $SearchDirs) { Write-Host "        $d" -ForegroundColor Red }
    Add-Failure "Step 9" "LIS source folder missing from the package"
    $script:LisCopyResult = "FAILED (source missing)"
} else {
    Write-Info "Source: $lisSrc"
    $destExisted = Test-Path -LiteralPath $LisDest -PathType Container

    if ($destExisted -and (-not $LisReplace)) {
        # The technician answered No (or a silent run did not opt in). Bypassing the copy
        # and carrying on is the documented behaviour - C:\LIS\Barcode\Backup and
        # C:\LIS\log on a live till hold data nobody wants silently overwritten.
        Write-Skip "$LisDest already exists and replace was declined - folder left untouched."
        Write-Info "Step 10 will still update the printer names in the existing config."
        $script:LisCopyResult = "skipped (existing folder kept)"
    } else {
        if ($destExisted) {
            Write-Info "$LisDest exists and replace was approved - files will be overwritten."
        }
        try {
            if (-not $destExisted) {
                New-Item -ItemType Directory -Force -Path $LisDest -ErrorAction Stop | Out-Null
            }

            # robocopy /E rather than Copy-Item -Recurse: /E recreates the empty folders the
            # package ships on purpose (A4\Backup, Barcode\Backup, Barcode\Log, back, log),
            # which AutoPrintFiles expects to already exist. No /PURGE - overwrite what we
            # ship, but never delete a file the client put there.
            $rcOut = & robocopy $lisSrc $LisDest /E /R:1 /W:1 /NP /NJH /NJS 2>&1
            $rc    = $LASTEXITCODE
            Write-CapturedOutput -Label "robocopy" -Text ($rcOut | Out-String) -MaxLines 20

            # robocopy is not a normal exit code: bits 0-3 are "work done", 8 and above
            # are real failures. Treating anything non-zero as an error would fail every
            # successful copy.
            if ($rc -ge 8) {
                Write-Bad "robocopy reported failure (exit $rc) copying to $LisDest."
                Add-Failure "Step 9" "robocopy exit $rc while copying LIS to $LisDest"
                $script:LisCopyResult = "FAILED (robocopy $rc)"
            } else {
                # Verify the payload landed rather than trusting the exit code
                $probe = Join-Path $LisDest "app\AutoPrintFiles.exe"
                if (Test-Path -LiteralPath $probe) {
                    $n = @(Get-ChildItem -LiteralPath $LisDest -Recurse -File -ErrorAction SilentlyContinue).Count
                    Write-Ok "$(if ($destExisted) { 'Replaced' } else { 'Created' }) $LisDest ($n file(s), robocopy $rc)"
                    $script:LisCopyResult = "$(if ($destExisted) { 'replaced' } else { 'created' }) ($n files)"
                } else {
                    Write-Bad "Copy finished but $probe is missing."
                    Add-Failure "Step 9" "AutoPrintFiles.exe missing from $LisDest after copy"
                    $script:LisCopyResult = "FAILED (payload incomplete)"
                }
            }
        } catch {
            Write-Bad "Could not copy the LIS folder: $($_.Exception.Message)"
            Add-Failure "Step 9" "LIS copy failed: $($_.Exception.Message)"
            $script:LisCopyResult = "FAILED ($($_.Exception.Message))"
        }
    }
}

# =====================================================================
# STEP 10: Write the printer names into AutoPrintFiles.exe.config
# =====================================================================
Write-StepTitle "[Step 10] Setting the barcode / A4 printer names..."

$AutoPrintDir = Join-Path $LisDest "app"
$cfgPath      = Join-Path $AutoPrintDir "AutoPrintFiles.exe.config"

if (-not $BarcodePrinter -and -not $A4Printer) {
    Write-Skip "No printer names supplied - the config file was left unchanged."
    $script:CfgResult = "unchanged (no printers supplied)"
} elseif (-not (Test-Path -LiteralPath $cfgPath)) {
    Write-Bad "$cfgPath not found - the printer names were not written."
    Add-Failure "Step 10" "AutoPrintFiles.exe.config not found at $cfgPath"
    $script:CfgResult = "FAILED (config not found)"
} else {
    try {
        # Parsed as XML, not rewritten with a regex: the file is a .NET app.config and a
        # botched value attribute makes AutoPrintFiles fail to start with a
        # ConfigurationErrorsException rather than just printing to the wrong device.
        $xml = New-Object System.Xml.XmlDocument
        $xml.PreserveWhitespace = $true
        $xml.Load($cfgPath)

        $appSettings = $xml.SelectSingleNode("/configuration/appSettings")
        if (-not $appSettings) { throw "no <appSettings> section in the config file" }

        # Keeps a copy of the config as found, once per run, before the first change
        $bak = "$cfgPath.bak"
        Copy-Item -LiteralPath $cfgPath -Destination $bak -Force -ErrorAction SilentlyContinue

        # "BarcodPrinter" is the spelling in the shipped config and the one
        # AutoPrintFiles reads. "BarcodePrinter" is accepted as an alias only because a
        # client config may already have been hand-corrected; whichever key is present
        # is the one updated, and neither spelling is added alongside the other.
        $targets = @(
            @{ Label = "Barcode printer"; Value = $BarcodePrinter; Keys = @("BarcodPrinter", "BarcodePrinter") },
            @{ Label = "A4 printer";      Value = $A4Printer;      Keys = @("A4Printer")                       }
        )

        $changed = @()
        foreach ($t in $targets) {
            if (-not $t.Value) {
                Write-Skip "$($t.Label): not supplied, existing value kept."
                continue
            }

            $node = $null
            foreach ($k in $t.Keys) {
                $node = $appSettings.SelectSingleNode("add[@key='$k']")
                if ($node) { break }
            }

            if ($node) {
                $old = $node.GetAttribute("value")
                $node.SetAttribute("value", $t.Value)
                if ($old -eq $t.Value) {
                    Write-Ok "$($t.Label): already '$($t.Value)', unchanged."
                } else {
                    Write-Ok "$($t.Label): '$old' -> '$($t.Value)'"
                }
                $changed += "$($node.GetAttribute('key'))=$($t.Value)"
            } else {
                # Absent key: add it under the canonical shipped spelling
                $new = $xml.CreateElement("add")
                $new.SetAttribute("key",   $t.Keys[0])
                $new.SetAttribute("value", $t.Value)
                $appSettings.AppendChild($new) | Out-Null
                Write-Ok "$($t.Label): key '$($t.Keys[0])' was missing, added = '$($t.Value)'"
                $changed += "$($t.Keys[0])=$($t.Value)"
            }
        }

        $xml.Save($cfgPath)

        # Read the file back from disk and confirm what a fresh XML parse sees, so a
        # save that silently produced an unusable file cannot be reported as success.
        $verify = New-Object System.Xml.XmlDocument
        $verify.Load($cfgPath)
        $bad = @()
        foreach ($t in $targets) {
            if (-not $t.Value) { continue }
            $got = $null
            foreach ($k in $t.Keys) {
                $n = $verify.SelectSingleNode("/configuration/appSettings/add[@key='$k']")
                if ($n) { $got = $n.GetAttribute("value"); break }
            }
            if ($got -ne $t.Value) { $bad += "$($t.Label) read back as '$got'" }
        }

        if ($bad.Count -gt 0) {
            foreach ($b in $bad) { Write-Bad $b }
            Add-Failure "Step 10" ($bad -join "; ")
            $script:CfgResult = "FAILED (" + ($bad -join "; ") + ")"
        } else {
            Write-Ok "Verified in $cfgPath"
            $script:CfgResult = ($changed -join ", ")
        }
    } catch {
        Write-Bad "Could not update the config file: $($_.Exception.Message)"
        Add-Failure "Step 10" "AutoPrintFiles.exe.config update failed: $($_.Exception.Message)"
        $script:CfgResult = "FAILED ($($_.Exception.Message))"
    }
}

# =====================================================================
# STEP 11: 'AutoPrint' desktop shortcut
# =====================================================================
Write-StepTitle "[Step 11] Creating the 'AutoPrint' shortcut on the desktop..."

$autoPrintExe = Join-Path $AutoPrintDir "AutoPrintFiles.exe"
if (-not (Test-Path -LiteralPath $autoPrintExe)) {
    Write-Bad "$autoPrintExe not found - the AutoPrint shortcut was not created."
    Add-Failure "Step 11" "AutoPrintFiles.exe not found at $autoPrintExe"
    $script:AutoPrintLnk = "FAILED (target missing)"
} else {
    # Public Desktop, matching the LDM shortcut in Step 8, so every user of the till
    # gets it rather than only the account the technician happened to install under.
    $desktopDir  = Join-Path $env:PUBLIC "Desktop"
    $apLnk       = Join-Path $desktopDir "AutoPrint.lnk"
    $shellAp     = $null
    try {
        if (-not (Test-Path -LiteralPath $desktopDir)) {
            New-Item -ItemType Directory -Force -Path $desktopDir -ErrorAction Stop | Out-Null
        }
        $shellAp = New-Object -ComObject WScript.Shell
        $sc = $shellAp.CreateShortcut($apLnk)
        $sc.TargetPath       = $autoPrintExe
        # WorkingDirectory matters here: AutoPrintFiles resolves its .config and the
        # relative folders it watches against the current directory.
        $sc.WorkingDirectory = $AutoPrintDir
        $sc.IconLocation     = "$autoPrintExe,0"
        $sc.Description      = "LIS AutoPrint - barcode and A4 print service"
        $sc.Save()

        if (Test-Path -LiteralPath $apLnk) {
            Write-Ok "Created: $apLnk"
            Write-Info "Target: $autoPrintExe"
            $script:AutoPrintLnk = "created"
        } else {
            Write-Bad "Save() reported no error but $apLnk does not exist."
            Add-Failure "Step 11" "AutoPrint shortcut was not created at $apLnk"
            $script:AutoPrintLnk = "FAILED (not created)"
        }
    } catch {
        Write-Bad "Could not create the AutoPrint shortcut: $($_.Exception.Message)"
        Add-Failure "Step 11" "AutoPrint desktop shortcut failed: $($_.Exception.Message)"
        $script:AutoPrintLnk = "FAILED ($($_.Exception.Message))"
    } finally {
        if ($shellAp) {
            try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shellAp) | Out-Null } catch { }
        }
    }
}

# =====================================================================
#  Result
# =====================================================================
Write-Host ""
Write-Host "=======================================================" -ForegroundColor Cyan
if ($script:Failures.Count -eq 0) {
    Write-Host "        DEPLOYMENT COMPLETED SUCCESSFULLY              " -ForegroundColor Green
} else {
    Write-Host "   DEPLOYMENT COMPLETED WITH $($script:Failures.Count) FAILURE(S)   " -ForegroundColor Red
}
Write-Host "=======================================================" -ForegroundColor Cyan

if ($script:Failures.Count -gt 0) {
    Write-Host ""
    Write-Host "FAILURES:" -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
}
if ($script:Warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "WARNINGS:" -ForegroundColor Yellow
    foreach ($w in $script:Warnings) { Write-Host "  - $w" -ForegroundColor Yellow }
}

Write-Host ""
Write-Host "Restart Microsoft Edge before launching Oracle Forms." -ForegroundColor Cyan
if ($script:RebootRequired) {
    Write-Host "A REBOOT is required to finish one or more installations." -ForegroundColor Yellow
}
if ($LogFile) { Write-Host "Log saved to: $LogFile" -ForegroundColor Cyan }

# ---------------------------------------------------------------------
#  Short summary file. The full transcript can run to hundreds of KB; this is the
#  few-KB version a customer can actually email back. Written to a stable name so
#  support can ask for one specific file.
# ---------------------------------------------------------------------
$exitCode = 0
if ($script:Failures.Count -gt 0) { $exitCode = 1 }

$summary = New-Object System.Collections.Generic.List[string]
$summary.Add("Oracle Forms 11g Client Deployment - Result Summary")
$summary.Add("===================================================")
$summary.Add("Computer      : $env:COMPUTERNAME")
$summary.Add("User          : $env:USERDOMAIN\$env:USERNAME")
$summary.Add("Date          : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$summary.Add("URL           : $FormsUrl")
$summary.Add("Server        : $ServerAuthority$(if ($FormsConfig) { " (config=$FormsConfig)" })")
$summary.Add("Branch code   : $(if ($BranchCode) { "$BranchCode -> $(Get-Hklm64String -SubKey 'SOFTWARE\WOW6432Node\branch_code'  -ValueName 'branch_code')"  } else { '(not supplied)' })")
$summary.Add("Lab code      : $(if ($LabCode)    { "$LabCode -> $(Get-Hklm64String -SubKey 'SOFTWARE\WOW6432Node\lab_location' -ValueName 'lab_location')" } else { '(not supplied)' })")
$summary.Add("LDM shortcut  : $(if (Test-Path -LiteralPath (Join-Path $env:PUBLIC 'Desktop\LDM.lnk')) { 'created' } else { 'MISSING' })")
$summary.Add("Mixed code    : $(if ($script:MixcodeApplied) { $script:MixcodeApplied } else { '(not applied)' })")
$summary.Add("LIS folder    : $script:LisCopyResult")
$summary.Add("Barcode ptr   : $(if ($BarcodePrinter) { $BarcodePrinter } else { '(not supplied)' })")
$summary.Add("A4 printer    : $(if ($A4Printer)      { $A4Printer      } else { '(not supplied)' })")
$summary.Add("AutoPrint cfg : $script:CfgResult")
$summary.Add("AutoPrint lnk : $script:AutoPrintLnk")
$summary.Add("Package       : $SourceDir")
$summary.Add("Silent mode   : $([bool]$Silent)")
$summary.Add("Java 8 found  : $(if (Get-Jre8Dir) { Get-Jre8Dir } else { 'NONE' })")
$summary.Add("Reboot needed : $script:RebootRequired")
$summary.Add("Result        : $(if ($exitCode -eq 0) { 'SUCCESS' } else { "FAILED ($($script:Failures.Count) failure(s))" })")
$summary.Add("Exit code     : $exitCode")
# Recorded even if the copy later fails, so the intended destination is always visible
$summary.Add("Log copy dest : $(if ($LogCopyDir) { $LogCopyDir } else { '(none requested)' })")
$summary.Add("")
if ($script:Failures.Count -gt 0) {
    $summary.Add("FAILURES:")
    foreach ($f in $script:Failures) { $summary.Add("  - $f") }
    $summary.Add("")
}
if ($script:Warnings.Count -gt 0) {
    $summary.Add("WARNINGS:")
    foreach ($w in $script:Warnings) { $summary.Add("  - $w") }
    $summary.Add("")
}
if ($LogFile) { $summary.Add("Full transcript: $LogFile") }

$summaryFile = $null
try {
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
    $summaryFile = Join-Path $LogDir ("LAST_RESULT_{0}.txt" -f $env:COMPUTERNAME)
    Set-Content -LiteralPath $summaryFile -Value $summary -Encoding ASCII
    Write-Host "Summary saved to: $summaryFile" -ForegroundColor Cyan
} catch {
    Write-Host "Could not write the summary file: $($_.Exception.Message)" -ForegroundColor Yellow
    $summaryFile = $null
}

try { Stop-Transcript | Out-Null } catch { }

# Copy the logs somewhere the technician will actually look (next to the installer).
# Deliberately after Stop-Transcript so the transcript is complete and closed.
if ($LogCopyDir) {
    # The transcript is already closed, so Write-Host here reaches the console only.
    # The outcome is therefore APPENDED to the summary file, which is the durable
    # record - previously there was no way to tell afterwards whether this ran.
    $copyResult = ""
    try {
        if (-not (Test-Path -LiteralPath $LogCopyDir)) {
            New-Item -ItemType Directory -Force -Path $LogCopyDir -ErrorAction Stop | Out-Null
        }
        # Transcript first, then the summary, so the summary carries the final verdict
        if ($LogFile -and (Test-Path -LiteralPath $LogFile)) {
            Copy-Item -LiteralPath $LogFile -Destination $LogCopyDir -Force -ErrorAction Stop
        }
        $copyResult = "Log copy      : OK -> $LogCopyDir"
        Write-Host "Logs copied to: $LogCopyDir" -ForegroundColor Cyan
    } catch {
        # Read-only share, CD, or a full disk - not worth failing the deployment over
        $copyResult = "Log copy      : FAILED -> $LogCopyDir ($($_.Exception.Message))"
        Write-Host "Could not copy logs to '$LogCopyDir': $($_.Exception.Message)" -ForegroundColor Yellow
    }

    if ($summaryFile) {
        try { Add-Content -LiteralPath $summaryFile -Value $copyResult -Encoding ASCII } catch { }
        # Copy the summary last so the copy at the destination includes the verdict above
        try {
            Copy-Item -LiteralPath $summaryFile -Destination $LogCopyDir -Force -ErrorAction Stop
        } catch {
            Write-Host "Could not copy the summary to '$LogCopyDir': $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# Only wait for a key when a human is actually watching - ReadKey throws or hangs
# under SCCM / Intune / PsExec / scheduled tasks.
if ($Interactive) {
    Write-Host ""
    Write-Host "Press any key to exit..."
    try { $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null } catch { }
}

exit $exitCode

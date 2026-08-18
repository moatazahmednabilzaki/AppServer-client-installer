#Requires -Version 3.0
<#
    Oracle Forms 11g - Enterprise Client Deployment

    Steps:
      1. Remove old Java (5 / 6)
      2. Install the 32-bit JRE 8 shipped alongside this script
      3. Import the SSL certificate chain
      4. Apply Edge IE Mode + Java Control Panel policy
      5. Install Adobe Reader XI silently
      6. Pre-approve the Java browser plug-in (java-plugin-preapprove.reg)

    Run via Deploy.bat (which enforces elevation). Requires Administrator.
    A full log is written to C:\ProgramData\AppServerClientInstaller\Logs.
#>

Start-Sleep -Milliseconds 500
Clear-Host
$Host.UI.RawUI.WindowTitle = "Oracle Forms 11g - Automated Deployment"

# =====================================================================
#  CONFIGURATION - this is the only block you should need to edit
# =====================================================================
$ServerHost   = "100.74.53.100"   # Forms server (must match the leaf cert CN)
$FormsConfig  = "LDM"             # the frmservlet ?config= value
$SiteListVer  = 2                 # !! BUMP THIS whenever the IE Mode site list
                                  #    below changes, or Edge keeps its cached copy
$MinJreUpdate = 241               # reinstall if the installed 8uNNN is older than this
$FallbackDir  = "C:\Java_8_upgrade"   # legacy staging path, still searched
$LogDir       = Join-Path $env:ProgramData "AppServerClientInstaller\Logs"
# =====================================================================

$SiteUrl  = "https://$ServerHost"
$FormsUrl = "https://$ServerHost/forms/frmservlet?config=$FormsConfig"

# Where this package actually lives. Previously the installer and certificate
# paths were hardcoded to C:\Java_8_upgrade, so running the package from a USB
# stick or a share silently skipped Step 2 and Step 3 entirely.
$SourceDir = $PSScriptRoot
if (-not $SourceDir) { $SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $SourceDir) { $SourceDir = (Get-Location).Path }

$SearchDirs = @($SourceDir)
if ((Test-Path $FallbackDir) -and ($FallbackDir.TrimEnd('\') -ine $SourceDir.TrimEnd('\'))) {
    $SearchDirs += $FallbackDir
}

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

$Interactive = $true
try { $Interactive = -not [Console]::IsOutputRedirected } catch { $Interactive = $false }

function Add-Failure { param([string]$Step, [string]$Message) $script:Failures += "[$Step] $Message" }
function Add-Warning { param([string]$Step, [string]$Message) $script:Warnings += "[$Step] $Message" }

function Write-StepTitle { param($Text) Write-Host ""; Write-Host $Text -ForegroundColor Yellow }
function Write-Ok        { param($Text) Write-Host "   -> $Text" -ForegroundColor Green }
function Write-Info      { param($Text) Write-Host "   -> $Text" -ForegroundColor White }
function Write-Skip      { param($Text) Write-Host "   -> SKIPPED: $Text" -ForegroundColor DarkGray }
function Write-Attention { param($Text) Write-Host "   -> WARNING: $Text" -ForegroundColor Yellow }
function Write-Bad       { param($Text) Write-Host "   -> FAILED: $Text" -ForegroundColor Red }

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
        [int[]]  $SuccessCodes = @(0)
    )
    $spin = @('-', '\', '|', '/')
    Write-Host -NoNewline "   -> $Text  "

    # Built with ProcessStartInfo instead of "Start-Process -PassThru": the latter
    # does not reliably retain the process handle, so $proc.ExitCode reads back as
    # empty once the process has exited - which would make every single step look
    # like a failure. A directly-created Process owns its handle, so ExitCode is
    # valid after exit. UseShellExecute=$false also means console children (cscript,
    # certutil, reg) share this console, so their output lands in the transcript.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $FilePath
    $psi.Arguments       = $Arguments
    $psi.UseShellExecute = $false

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

    $i = 0
    while (-not $proc.HasExited) {
        if ($Interactive) { try { [Console]::Write("`b" + $spin[$i % 4]) } catch { } }
        $i++
        Start-Sleep -Milliseconds 150
    }
    $proc.WaitForExit()
    if ($Interactive) { try { [Console]::Write("`b") } catch { } }

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
        foreach ($f in @(Get-ChildItem -Path $dir -Filter $Pattern -File -ErrorAction SilentlyContinue)) {
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
    if (-not (Test-Path $JavaRootDir)) { return $null }
    $dir = Get-ChildItem -Path $JavaRootDir -Filter "jre1.8.0*" -Directory -ErrorAction SilentlyContinue |
           Where-Object { Test-Path (Join-Path $_.FullName 'bin\java.exe') } |
           Sort-Object { Get-JavaUpdateNumber $_.Name } -Descending |
           Select-Object -First 1
    if ($dir) { return $dir.FullName }
    return $null
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
Write-Host "  Server   : $ServerHost (config=$FormsConfig)"
Write-Host "  Package  : $SourceDir"
if ($LogFile) { Write-Host "  Log      : $LogFile" }
else          { Write-Host "  Log      : (could not be created)" -ForegroundColor Yellow }
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
    foreach ($f in @(Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue |
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
                               -Arguments "-addstore -f `"Root`" `"$($cert.FullName)`""
        if ($code -eq 0) {
            Write-Ok "Certificate $($cert.Name) installed successfully!"
        } else {
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
$xmlContent = @"
<site-list version="$SiteListVer">
  <site url="$ServerHost">
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

# Set properties without locking them, allowing manual override
$props = "deployment.security.level=HIGH`r`ndeployment.security.mixcode=HIDE_UNTRUSTED`r`ndeployment.security.revocation.check=NO_CHECK`r`ndeployment.security.tls.revocation.check=NO_CHECK`r`ndeployment.security.validation.crl=false`r`ndeployment.security.validation.ocsp=false`r`ndeployment.security.TLSv1=true`r`ndeployment.security.TLSv1.1=true`r`ndeployment.javaws.jre.0.args=-Dsun.java2d.noddraw=true -Dsun.java2d.d3d=false`r`ndeployment.user.security.exception.sites=C:/Windows/Sun/Java/Deployment/security/exception.sites`r`ndeployment.expiration.check.enabled=false`r`ndeployment.javaws.autodownload=NEVER"
[System.IO.File]::WriteAllText("$sysDeployDir\deployment.properties", $props)

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

Show-TextSpinner -Text "Patching Security Algorithms (MD5/SHA1)..." -Seconds 1
$javaDir = Get-Jre8Dir
if ($javaDir) {
    $securityFile = "$javaDir\lib\security\java.security"
    if (Test-Path $securityFile) {
        $content = Get-Content $securityFile
        $content = $content -replace 'MD5, ', '' -replace 'MD2, ', ''
        $content = $content -replace '& denyAfter \d{4}-\d{2}-\d{2}', ''
        $content = $content -replace 'RSA keySize < \d+', 'RSA keySize < 512'
        $content | Set-Content $securityFile
    } else {
        Write-Attention "java.security not found at $securityFile"
        Add-Warning "Step 4" "java.security not found - algorithm patch skipped"
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
if (Test-Path $ieFixFile) {
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
                           -Arguments "//nologo `"$ieFixFile`" `"$iniPath`""
    if ($code -ne 0) { Add-Warning "Step 4" "IEModeExpiryFix.vbs exited with $code" }
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
                           -Arguments "import `"$($regFile.FullName)`""
    if ($code -eq 0) {
        Write-Ok "Java plug-in pre-approved (64-bit and Wow6432Node views)."
    } else {
        Add-Failure "Step 6" "reg import of $($regFile.Name) failed (exit $code)"
    }
} else {
    Write-Bad "java-plugin-preapprove.reg not found in:"
    foreach ($d in $SearchDirs) { Write-Host "        $d" -ForegroundColor Red }
    Add-Failure "Step 6" "java-plugin-preapprove.reg missing from the package"
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

try { Stop-Transcript | Out-Null } catch { }

# Only wait for a key when a human is actually watching - ReadKey throws or hangs
# under SCCM / Intune / PsExec / scheduled tasks.
if ($Interactive) {
    Write-Host ""
    Write-Host "Press any key to exit..."
    try { $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null } catch { }
}

if ($script:Failures.Count -gt 0) { exit 1 }
exit 0

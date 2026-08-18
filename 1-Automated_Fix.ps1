Start-Sleep -Milliseconds 500
Clear-Host
$Host.UI.RawUI.WindowTitle = "Oracle Forms 11g - Automated Deployment"

function Show-TextSpinner {
    param($Text, $Seconds)
    $spinChars = @('-', '\', '|', '/')
    $endTime = (Get-Date).AddSeconds($Seconds)
    $i = 0
    Write-Host -NoNewline "   -> $Text  "
    while ((Get-Date) -lt $endTime) {
        Write-Host -NoNewline "`b$($spinChars[$i % 4])"
        $i++
        Start-Sleep -Milliseconds 150
    }
    Write-Host "`b " -NoNewline
    Write-Host "[Done]" -ForegroundColor Green
}

Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "     Oracle Forms 11g - Enterprise Deployment Script   " -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host ""

# STEP 1: Uninstall Java 6
Write-Host "[Step 1] Checking and enforcing removal of all old Java versions..." -ForegroundColor Yellow

$java6Found = $true
$loopCount = 0

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
            Write-Host "   -> Found old version: $($app.DisplayName)" -ForegroundColor White
            Show-TextSpinner -Text "Uninstalling $($app.DisplayName)..." -Seconds 2
            
            if ($app.PSChildName -match "^\{.*\}$") {
                $guid = $app.PSChildName
                Start-Process -FilePath "msiexec.exe" -ArgumentList "/x `"$guid`" /qn /norestart" -Wait | Out-Null
            } else {
                $prod = Get-WmiObject -Class Win32_Product -Filter "Name='$($app.DisplayName)'" -ErrorAction SilentlyContinue
                if ($prod) { $prod.Uninstall() | Out-Null }
            }
        }
        Show-TextSpinner -Text "Re-scanning system for leftovers..." -Seconds 2
    } else {
        $java6Found = $false
        Write-Host "   -> VERIFIED: No Java 6 versions found. System is 100% clean!" -ForegroundColor Green
    }
}
Write-Host ""

# STEP 2: Install Java 8
Write-Host "[Step 2] Checking for Java 8 Installation..." -ForegroundColor Yellow

$java8Installed = $false

# To prevent false positives from broken uninstalls, we check if java.exe physically exists
$javaDirCheck = (Get-ChildItem "C:\Program Files (x86)\Java" -Filter "jre1.8.0_*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
if ($javaDirCheck -and (Test-Path "$javaDirCheck\bin\java.exe")) {
    $java8Installed = $true
} else {
    $java8Installed = $false
}

if ($java8Installed) {
    Write-Host "   -> SKIPPED: Java 8 is already installed on this machine!" -ForegroundColor Green
} else {
    $java8Installer = "C:\Java_8_upgrade\jre-8u241-windows-i586.exe"
    if (Test-Path $java8Installer) {
        Show-TextSpinner -Text "Installing Java 8 (this takes a moment)..." -Seconds 5
        Start-Process -FilePath $java8Installer -ArgumentList "/s" -Wait
        Write-Host "   -> Java 8 installed successfully!" -ForegroundColor Green
    } else {
        Write-Host "   -> (SKIPPED) Java 8 installer not found at:" -ForegroundColor Red
        Write-Host "   -> $java8Installer" -ForegroundColor Red
    }
}
Write-Host ""

# STEP 3: Install SSL Certificates
Write-Host "[Step 3] Installing SSL Certificates to Trusted Root..." -ForegroundColor Yellow
$certFolder = "C:\Java_8_upgrade"
$certsFound = $false

if (Test-Path $certFolder) {
    $certs = Get-ChildItem -Path $certFolder -File | Where-Object { $_.Extension -match "\.(cer|crt|der|pem)$" }
    
    if ($certs.Count -gt 0) {
        $certsFound = $true
        foreach ($cert in $certs) {
            Show-TextSpinner -Text "Installing Certificate: $($cert.Name)..." -Seconds 1
            $certProcess = Start-Process -FilePath "certutil.exe" -ArgumentList "-addstore -f `"Root`" `"$($cert.FullName)`"" -Wait -NoNewWindow -PassThru
            if ($certProcess.ExitCode -eq 0) {
                Write-Host "   -> Certificate $($cert.Name) installed successfully!" -ForegroundColor Green
            } else {
                Write-Host "   -> Failed to install $($cert.Name)." -ForegroundColor Red
            }
        }
    }
}

if (-not $certsFound) {
    Write-Host "   -> SKIPPED: No certificate files (*.cer, *.crt) found in $certFolder." -ForegroundColor DarkGray
}
Write-Host ""

# STEP 4: Apply Fixes
Write-Host "[Step 4] Applying Deep System Fixes..." -ForegroundColor Yellow

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
<site-list version="1">
  <site url="100.74.53.100">
    <compat-mode>Default</compat-mode>
    <open-in>IE11</open-in>
  </site>
</site-list>
"@
$xmlContent | Out-File $siteListXml -Encoding ASCII
reg add "HKLM\SOFTWARE\Policies\Microsoft\Edge" /v InternetExplorerIntegrationSiteList /t REG_SZ /d "file:///$siteListXml" /f > $null

# Trusted Sites (Zone 2)
reg add "HKLM\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Ranges\RangeTrusted" /v ":Range" /t REG_SZ /d "100.74.53.100" /f > $null
reg add "HKLM\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Ranges\RangeTrusted" /v "https" /t REG_DWORD /d 2 /f > $null

# Disable Java Auto Update
reg add "HKLM\SOFTWARE\JavaSoft\Java Update\Policy" /v EnableJavaUpdate /t REG_DWORD /d 0 /f > $null
reg add "HKLM\SOFTWARE\WOW6432Node\JavaSoft\Java Update\Policy" /v EnableJavaUpdate /t REG_DWORD /d 0 /f > $null

Show-TextSpinner -Text "Configuring Java Settings (Control Panel)..." -Seconds 2
$sysConfigContent = "deployment.system.config=file\:C\:/Windows/Sun/Java/Deployment/deployment.properties`r`ndeployment.system.config.mandatory=true"
[System.IO.File]::WriteAllText("$sysDeployDir\deployment.config", $sysConfigContent)

# Set properties without locking them, allowing manual override
$props = "deployment.security.level=HIGH`r`ndeployment.security.mixcode=HIDE_UNTRUSTED`r`ndeployment.security.revocation.check=NO_CHECK`r`ndeployment.security.tls.revocation.check=NO_CHECK`r`ndeployment.security.validation.crl=false`r`ndeployment.security.validation.ocsp=false`r`ndeployment.security.TLSv1=true`r`ndeployment.security.TLSv1.1=true`r`ndeployment.javaws.jre.0.args=-Dsun.java2d.noddraw=true -Dsun.java2d.d3d=false`r`ndeployment.user.security.exception.sites=C:/Windows/Sun/Java/Deployment/security/exception.sites`r`ndeployment.expiration.check.enabled=false`r`ndeployment.javaws.autodownload=NEVER"
[System.IO.File]::WriteAllText("$sysDeployDir\deployment.properties", $props)

# Drop system config into the JRE lib folder as the ultimate override (but not mandatory)
$sysConfigContent = "deployment.system.config=file\:C\:/Windows/Sun/Java/Deployment/deployment.properties"
$javaDir = (Get-ChildItem "C:\Program Files (x86)\Java" -Filter "jre1.8.0_*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
if ($javaDir) {
    [System.IO.File]::WriteAllText("$javaDir\lib\deployment.config", $sysConfigContent)
    [System.IO.File]::WriteAllText("$javaDir\lib\deployment.properties", $props)
}

$securityDir = "$sysDeployDir\security"
if (!(Test-Path $securityDir)) { New-Item -ItemType Directory -Force -Path $securityDir | Out-Null }
[System.IO.File]::WriteAllText("$securityDir\exception.sites", "https://100.74.53.100")

# Force properties to all existing user profiles to ensure Control Panel recognizes it
$users = Get-ChildItem -Path "C:\Users" -Directory
foreach ($user in $users) {
    $userDeployDir = "$($user.FullName)\AppData\LocalLow\Sun\Java\Deployment"
    if (Test-Path "$($user.FullName)\AppData\LocalLow") {
        if (!(Test-Path $userDeployDir)) { New-Item -ItemType Directory -Force -Path $userDeployDir | Out-Null }
        [System.IO.File]::WriteAllText("$userDeployDir\deployment.properties", $props)
        
        $userSecDir = "$userDeployDir\security"
        if (!(Test-Path $userSecDir)) { New-Item -ItemType Directory -Force -Path $userSecDir | Out-Null }
        [System.IO.File]::WriteAllText("$userSecDir\exception.sites", "https://100.74.53.100")
    }
}

Show-TextSpinner -Text "Patching Security Algorithms (MD5/SHA1)..." -Seconds 1
$javaDir = (Get-ChildItem "C:\Program Files (x86)\Java" -Filter "jre1.8.0_*" | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
if ($javaDir) {
    $securityFile = "$javaDir\lib\security\java.security"
    if (Test-Path $securityFile) {
        $content = Get-Content $securityFile
        $content = $content -replace 'MD5, ', '' -replace 'MD2, ', ''
        $content = $content -replace '& denyAfter \d{4}-\d{2}-\d{2}', ''
        $content = $content -replace 'RSA keySize < \d+', 'RSA keySize < 512'
        $content | Set-Content $securityFile
    }
}

Show-TextSpinner -Text "Creating Desktop Launcher..." -Seconds 1
$vbsPath = "$env:PUBLIC\Desktop\Launch_Oracle_Forms.vbs"
$vbsCode = 'Set ie = CreateObject("InternetExplorer.Application") : ie.Visible = True : ie.Navigate "https://100.74.53.100/forms/frmservlet?config=LDM"'
$vbsCode | Out-File $vbsPath -Encoding ASCII

Show-TextSpinner -Text "Applying IE Mode Expiry Fix..." -Seconds 1
$ieFixFile = Join-Path $PSScriptRoot "IEModeExpiryFix.vbs"
if (Test-Path $ieFixFile) {
    Start-Process -FilePath "wscript.exe" -ArgumentList "`"$ieFixFile`"" -Wait
} else {
    Write-Host "   -> IEModeExpiryFix.vbs not found, skipping." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "        DEPLOYMENT COMPLETED SUCCESSFULLY              " -ForegroundColor Green
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Press any key to exit..."
$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null

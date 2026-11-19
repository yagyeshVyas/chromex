# Installs the signed CHROMEX build on the connected iPhone.
#
#   powershell -ExecutionPolicy Bypass -File Scripts\install-to-iphone.ps1            # waits up to 60s for the phone
#   powershell -ExecutionPolicy Bypass -File Scripts\install-to-iphone.ps1 -WaitSeconds 300
#
# Signs the published unsigned IPA with the local certificate/profile if the
# signed archive is missing or stale, then installs and launches it.
param(
    [int]$WaitSeconds = 60
)

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$bundleId = 'app.mountain3690.pegasus6317'
$unsigned = 'dist/CHROMEX-unsigned.ipa'
$signed   = 'dist/CHROMEX-signed.ipa'

$certDir = 'D:/iosapp/00008130-000E35E60E30001C'
$p12 = "$certDir/00008130-000E35E60E30001C.p12"
$profile = "$certDir/00008130-000E35E60E30001C.mobileprovision"

function Write-Step($message) { Write-Host "== $message" -ForegroundColor Cyan }

if (-not (Test-Path $unsigned)) {
    throw "Missing $unsigned. Build or download the unsigned IPA first."
}

$needsSign = $true
if (Test-Path $signed) {
    $needsSign = (Get-Item $signed).LastWriteTimeUtc -lt (Get-Item $unsigned).LastWriteTimeUtc
}

if ($needsSign) {
    Write-Step 'Signing the IPA with the local certificate'
    if (-not (Test-Path $p12) -or -not (Test-Path $profile)) {
        throw 'Signing assets not found in 00008130-000E35E60E30001C.'
    }
    $wslPath = "/mnt/d/iosapp/chromex-browser"
    $command = "cd $wslPath && /work/zsign/bin/zsign -f " +
        "-k /mnt/d/iosapp/00008130-000E35E60E30001C/00008130-000E35E60E30001C.p12 -p WSF " +
        "-m /mnt/d/iosapp/00008130-000E35E60E30001C/00008130-000E35E60E30001C.mobileprovision " +
        "-b $bundleId -o dist/CHROMEX-signed.ipa dist/CHROMEX-unsigned.ipa"
    wsl -d Ubuntu -u root -- bash -lc $command | Select-Object -Last 4
}

Write-Step "Waiting up to $WaitSeconds s for the iPhone"
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$device = $null
while ((Get-Date) -lt $deadline) {
    $raw = & python -m pymobiledevice3 usbmux list 2>$null | Out-String
    try { $devices = $raw | ConvertFrom-Json } catch { $devices = @() }
    if ($devices -and @($devices).Count -gt 0) { $device = @($devices)[0]; break }
    Start-Sleep -Seconds 3
}

if (-not $device) {
    Write-Host ''
    Write-Host 'iPhone NOT detected.' -ForegroundColor Yellow
    Write-Host '  1. Connect the iPhone with a USB data cable (not charge-only).'
    Write-Host '  2. Unlock it and tap "Trust" on "Trust This Computer?".'
    Write-Host '  3. Keep it unlocked until installation finishes.'
    Write-Host '  4. Re-run: powershell -ExecutionPolicy Bypass -File Scripts\install-to-iphone.ps1 -WaitSeconds 300'
    Write-Host ''
    Write-Host 'Windows checks:'
    Write-Host '  Get-PnpDevice -PresentOnly | Where FriendlyName -match "Apple|iPhone"'
    Write-Host '  Get-Service "Apple Mobile Device Service"'
    exit 2
}

Write-Step "Found $($device.DeviceName) ($($device.ProductType), iOS $($device.ProductVersion))"

Write-Step 'Installing'
$installOutput = & python -m pymobiledevice3 apps install $signed 2>&1 | Out-String
if ($installOutput -notmatch 'Installation succeed') {
    Write-Host $installOutput
    throw 'Installation failed; see output above.'
}
Write-Host 'Installed.'

Write-Step 'Launching'
$launch = & python -m pymobiledevice3 developer core-device launch-application $bundleId 2>&1 | Out-String
if ($launch -match '"processIdentifier"\s*:\s*(\d+)') {
    Write-Host "Launched. PID $($Matches[1])."
} else {
    Write-Host $launch
    Write-Host 'Installed, but launch could not be confirmed. Tap CHROMEX on the phone.'
}

Write-Host ''
Write-Host 'CHROMEX is installed and running.' -ForegroundColor Green

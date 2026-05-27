param (
    [string]$Version
)

# 1. If version is not provided, prompt the user
if ([string]::IsNullOrEmpty($Version)) {
    $Version = Read-Host "Please enter the new APK version (e.g. v1.0.3)"
}

# Trim whitespace
$Version = $Version.Trim()

if (-not $Version.StartsWith("v")) {
    $Version = "v" + $Version
}

Write-Host "--------------------------------------------------" -ForegroundColor Cyan
Write-Host "Updating Android APK link & QR codes to version: $Version" -ForegroundColor Cyan
Write-Host "--------------------------------------------------" -ForegroundColor Cyan

# 2. Define the URLs
$rawUrl = "https://github.com/lomorage/lomo-mobile/releases/download/$Version/app-release.apk"
$apkUrl = "https://gfw.lomorage.com/$rawUrl"

Write-Host "New Domestic Accelerated Download Link:" -ForegroundColor Yellow
Write-Host $apkUrl -ForegroundColor White

# 3. Update zh/android.html
$htmlPath = "zh/android.html"
if (Test-Path $htmlPath) {
    Write-Host "Updating $htmlPath ..." -ForegroundColor Yellow
    
    # Read file using explicit UTF-8 to prevent ANSI corruption in PowerShell 5.1
    $htmlContent = [System.IO.File]::ReadAllText((Resolve-Path $htmlPath), [System.Text.Encoding]::UTF8)
    
    # Regex to replace the old APK download URL
    $regex = 'https://gfw\.lomorage\.com/https://github\.com/lomorage/lomo-mobile/releases/download/v[0-9\.]+/app-release\.apk'
    if ($htmlContent -match $regex) {
        $htmlContent = $htmlContent -replace $regex, $apkUrl
        
        # Write back as UTF-8 without BOM (standard for web files)
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Resolve-Path $htmlPath), $htmlContent, $utf8NoBom)
        
        Write-Host "Successfully updated $htmlPath!" -ForegroundColor Green
    } else {
        Write-Host "Warning: Could not find matching download URL in $htmlPath. Please verify." -ForegroundColor Red
    }
} else {
    Write-Host "Error: File $htmlPath not found" -ForegroundColor Red
    exit 1
}

# 4. Download and update QR codes
Write-Host "Requesting API to generate QR codes..." -ForegroundColor Yellow
$encodedUrl = [URI]::EscapeDataString($apkUrl)
$qrApiUrl = "https://api.qrserver.com/v1/create-qr-code/?size=500x500&data=$encodedUrl"

$zhQrPath = "zh/assets/images/android-apk-qrcode.png"
$enQrPath = "en/assets/images/android-apk-qrcode.png"

try {
    # Ensure parent directories exist
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $zhQrPath)
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $enQrPath)

    Write-Host "Downloading and overwriting Chinese QR code ($zhQrPath) ..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $qrApiUrl -OutFile $zhQrPath
    
    Write-Host "Downloading and overwriting English QR code ($enQrPath) ..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $qrApiUrl -OutFile $enQrPath
    
    Write-Host "QR codes updated successfully!" -ForegroundColor Green
} catch {
    Write-Host "Failed to generate/download QR codes: $_" -ForegroundColor Red
    exit 1
}

Write-Host "`n--------------------------------------------------" -ForegroundColor Green
Write-Host "🎉 Done! Run 'git diff' to review the modifications." -ForegroundColor Green
Write-Host "--------------------------------------------------" -ForegroundColor Green

<#
.SYNOPSIS
  One-click installer for lomod (lomorage's personal photo backup backend) on Windows.

.DESCRIPTION
  Intended to be run the same way Claude Code's own installer is:

      irm https://lomosw.lomorage.com/windows/install.ps1 | iex

  This is a secondary, advanced/CLI install path. The primary recommended Windows install is
  still the LomoAgent GUI installer (see en/windows.html on lomosw.github.io) -- this script
  installs the bare lomod backend with no GUI/tray/onboarding, for users who'd rather script it.

  Everything here runs at the current user's permission level -- no UAC prompt, no admin
  rights, no Windows Service. It installs into %LOCALAPPDATA%, autostarts via a shortcut in
  the per-user Startup folder (not the Windows Service Control Manager or an elevated
  Scheduled Task, both of which require elevation), and defaults to a single local backup
  folder with mDNS disabled so first run doesn't trigger a Windows Firewall prompt.

  Safe to re-run: it stops any already-running lomod.exe, replaces the install directory, and
  restarts it, so this script also serves as a manual repair/reinstall/update path pending a
  scheduled self-update wired on top of cmd/lomoupg.

.PARAMETER InstallDir
  Where lomod.exe and its bundled dependencies (vips DLLs, exiftool.exe, ffmpeg.exe/ffprobe.exe)
  are installed. Defaults to a per-user, admin-free location.

.PARAMETER DataDir
  Where photos/videos and the sqlite catalog are stored. Defaults to a local Pictures subfolder
  (the "single local folder" desktop mode -- no Samba/USB-mount/mDNS features).

.PARAMETER ReleaseUrl
  Where to fetch the release manifest (see installers/release.json.example for the schema).
  Defaults to the real production manifest also used by LomoAgent's own updater
  (homepage/static/release.json, deployed to https://lomorage.com/release.json) -- but this
  script reads a distinct -ManifestKey within it, never the "windows" key LomoAgent itself uses,
  so the two installers' release info can never collide.

.PARAMETER ManifestKey
  Which top-level key of the release manifest to read. Defaults to "windows-cli" (kept separate
  from LomoAgent's own "windows" key -- see homepage/updatever.sh's `wincli` platform option).

.PARAMETER NoBrowser
  Skip auto-opening the default browser to the local setup UI after install.
#>
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "Lomorage\lomod"),
    [string]$DataDir = (Join-Path $env:USERPROFILE "Pictures\Lomorage"),
    [string]$ReleaseUrl = "https://lomorage.com/release.json",
    [string]$ManifestKey = "windows-cli",
    [int]$Port = 8000,
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Warn2($msg) { Write-Host "!! $msg" -ForegroundColor Yellow }

function Get-Sha256Hex {
    # Not Get-FileHash: on some machines PSModulePath ordering resolves Microsoft.PowerShell.Utility
    # to an incompatible PowerShell-7-targeted copy from a WindowsApps package, silently breaking
    # Get-FileHash under Windows PowerShell 5.1. Raw .NET has no module-resolution dependency.
    param([string]$Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try { $hashBytes = $sha256.ComputeHash($stream) } finally { $stream.Close() }
    } finally {
        $sha256.Dispose()
    }
    return -join ($hashBytes | ForEach-Object { $_.ToString("x2") })
}

function Get-VerifiedFile {
    param([string]$Url, [string]$ExpectedSha256, [string]$OutFile)
    # curl.exe (built into Windows 10 1803+), not Invoke-WebRequest: some hosts (e.g. SourceForge's
    # Cloudflare bot-protection) serve Invoke-WebRequest an HTML page instead of the real file.
    & curl.exe -fsSL -o $OutFile $Url
    if ($LASTEXITCODE -ne 0) { throw "curl.exe failed downloading $Url (exit $LASTEXITCODE)" }
    $actual = Get-Sha256Hex -Path $OutFile
    if ($actual.ToLower() -ne $ExpectedSha256.ToLower()) {
        throw "Downloaded file $OutFile does not match the expected SHA256 in the release manifest.`nexpected: $ExpectedSha256`nactual:   $actual`nThis could mean a corrupted download or a tampered release -- aborting."
    }
}

function Stop-ExistingLomod {
    $stopScript = Join-Path $InstallDir "lomorage-stop.bat"
    if (Test-Path $stopScript) {
        Write-Step "Stopping any running lomod.exe"
        # Start-Process, not `& cmd /c ... | Out-Null`: piping through the pipeline blocks until
        # the pipe sees EOF, which never happens if a detached long-running child (lomod.exe)
        # inherits the same stdout handle. Start-Process with no output redirection has no such
        # handle to inherit, so -Wait only waits on cmd.exe's own exit, not any grandchildren.
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$stopScript`"" -WindowStyle Hidden -Wait
        Start-Sleep -Seconds 1
    }
}

function Register-Autostart {
    $startupDir = [Environment]::GetFolderPath("Startup")
    $shortcutPath = Join-Path $startupDir "Lomorage.lnk"
    $target = Join-Path $InstallDir "lomorage-start.bat"

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $target
    $shortcut.WorkingDirectory = $InstallDir
    $shortcut.WindowStyle = 7  # minimized
    $shortcut.Description = "Start lomorage photo backup"
    $shortcut.Save()
}

function Wait-ForLomod {
    param([int]$TimeoutSeconds = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/mount" -UseBasicParsing -TimeoutSec 2
            if ($resp.StatusCode -eq 200) { return $true }
        } catch {
            Start-Sleep -Milliseconds 500
        }
    }
    return $false
}

try {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -ne "AMD64") {
        Write-Warn2 "Only a Windows amd64 build of lomod is published today (detected $arch). It may still run under Windows-on-ARM x64 emulation, but this is untested."
    }

    Write-Step "Fetching release manifest from $ReleaseUrl"
    $manifest = Invoke-RestMethod -Uri $ReleaseUrl
    $platform = $manifest.$ManifestKey
    if (-not $platform -or -not $platform.URL -or -not $platform.SHA256) {
        throw "Release manifest at $ReleaseUrl has no usable '$ManifestKey' entry (expected URL + SHA256 fields, see installers/release.json.example)."
    }

    Stop-ExistingLomod

    Write-Step "Downloading lomod $($platform.Version)"
    $tmpZip = Join-Path $env:TEMP "lomorage-windows-$($platform.Version).zip"
    Get-VerifiedFile -Url $platform.URL -ExpectedSha256 $platform.SHA256 -OutFile $tmpZip

    Write-Step "Installing to $InstallDir"
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Expand-Archive -Path $tmpZip -DestinationPath $InstallDir -Force
    Remove-Item $tmpZip -Force

    Set-Content -Path (Join-Path $InstallDir "version.txt") -Value $platform.Version -NoNewline

    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    $lomodArgs = "--base `"$DataDir`" --exe-dir `"$InstallDir`" --no-mdns --port $Port"
    Set-Content -Path (Join-Path $InstallDir "lomod.args") -Value $lomodArgs -NoNewline

    Write-Step "Registering autostart (per-user, no admin required)"
    Register-Autostart

    Write-Step "Starting lomod"
    # No -Wait: cmd.exe here just runs `start ... lomod.exe` and exits almost immediately, but
    # Start-Process -Wait has a known quirk of blocking on further-detached grandchildren too
    # (lomod.exe itself keeps running) -- confirmed by lomod already answering HTTP requests while
    # -Wait was still blocked. Wait-ForLomod below is the actual readiness signal we need anyway.
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$(Join-Path $InstallDir 'lomorage-start.bat')`"" -WindowStyle Hidden

    if (Wait-ForLomod) {
        Write-Host ""
        Write-Host "lomorage is running: http://localhost:$Port" -ForegroundColor Green
        Write-Host "  install dir: $InstallDir"
        Write-Host "  data dir:    $DataDir"
        Write-Host "  it will start automatically next time you log in"
        Write-Host "  to stop it, run: $InstallDir\lomorage-stop.bat"
        if (-not $NoBrowser) {
            Start-Process "http://localhost:$Port"
        }
    } else {
        Write-Warn2 "lomod was installed and launched, but didn't respond on http://localhost:$Port within 30s. Check that nothing else is using that port, or run $InstallDir\lomod.exe directly from a terminal to see its output."
    }
} catch {
    Write-Host ""
    Write-Host "Install failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

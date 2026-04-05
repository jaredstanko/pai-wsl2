# Build PAI-Status tray app
# Compiles PAIStatus.cs using csc.exe (ships with .NET Framework on every Windows 10/11).
# Same pattern as PAI-LIMA's swiftc build — compile from source at install time.
#
# Usage:
#   .\trayapp\build.ps1                                    # Build default instance
#   .\trayapp\build.ps1 -Install                           # Build and launch
#   .\trayapp\build.ps1 -DistroName pai-v2 -Port 8082     # Named instance
#   .\trayapp\build.ps1 -AppName "PAI-Status-v2" -Install  # Custom app name
#
# PowerShell 5.1 compatible.

param(
    [string]$DistroName = "pai",
    [int]$Port = 8080,
    [string]$AppName = "PAI-Status",
    [switch]$Install
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$BuildDir = Join-Path $ScriptDir "build"
$PortalUrl = "http://localhost:$Port"

Write-Host "Building $AppName..."
Write-Host "  Distro:  $DistroName"
Write-Host "  Portal:  $PortalUrl"

# Find csc.exe from .NET Framework (ships with every Windows 10/11)
$cscPath = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $cscPath)) {
    # Try 32-bit framework
    $cscPath = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe"
}
if (-not (Test-Path $cscPath)) {
    Write-Host "ERROR: csc.exe not found. .NET Framework 4.x is required." -ForegroundColor Red
    Write-Host "       This ships with Windows 10/11 — check your installation." -ForegroundColor Red
    exit 1
}
Write-Host "  Compiler: $cscPath"

# Clean build directory
if (Test-Path $BuildDir) {
    Remove-Item -Recurse -Force $BuildDir
}
New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null

# Generate instance-specific C# source with correct constants
$sourceFile = Join-Path $ScriptDir "PAIStatus.cs"
$buildSource = Join-Path $BuildDir "PAIStatus.cs"

$source = Get-Content $sourceFile -Raw
$source = $source -replace 'private static string DistroName = "pai"', "private static string DistroName = `"$DistroName`""
$source = $source -replace 'private static string PortalUrl = "http://localhost:8080"', "private static string PortalUrl = `"$PortalUrl`""
$source = $source -replace 'private static string AppName = "PAI-Status"', "private static string AppName = `"$AppName`""
$source | Out-File -FilePath $buildSource -Encoding UTF8

# Compile
$exePath = Join-Path $BuildDir "$AppName.exe"

Write-Host "  Compiling..."
$compileArgs = @(
    "/nologo",
    "/target:winexe",           # Windows app (no console window)
    "/optimize+",
    "/out:$exePath",
    "/reference:System.dll",
    "/reference:System.Drawing.dll",
    "/reference:System.Windows.Forms.dll",
    $buildSource
)

& $cscPath @compileArgs 2>&1 | ForEach-Object {
    if ($_ -match "error") {
        Write-Host "  $_" -ForegroundColor Red
    }
}

if (-not (Test-Path $exePath)) {
    Write-Host "ERROR: Compilation failed." -ForegroundColor Red
    exit 1
}

# Clean up build source
Remove-Item $buildSource -Force

$size = [math]::Round((Get-Item $exePath).Length / 1024, 1)
Write-Host "  Built: $exePath ($size KB)" -ForegroundColor Green

# Install if requested
if ($Install) {
    # Kill any running instance
    Get-Process -Name $AppName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # Launch
    Write-Host "  Launching $AppName..."
    Start-Process $exePath
    Write-Host "  $AppName is running in the system tray." -ForegroundColor Green
}

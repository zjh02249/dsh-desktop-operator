[CmdletBinding()]
param(
    [switch]$RequireWindows11,

    [switch]$RequireInteractive
)

$ErrorActionPreference = "Stop"
$currentVersion = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$currentVersion.CurrentBuildNumber
$isWindows11 = $build -ge 22000 -and [string]$os.Caption -match "Windows"
$interactive = [Environment]::UserInteractive
$evidence = [pscustomobject]@{
    status = "passed"
    caption = [string]$os.Caption
    displayVersion = [string]$currentVersion.DisplayVersion
    version = [string]$os.Version
    build = $build
    architecture = [string]$os.OSArchitecture
    windows11 = $isWindows11
    interactiveSession = $interactive
    computerName = [Environment]::MachineName
}
if ($RequireWindows11 -and -not $isWindows11) {
    $evidence.status = "failed"
    $evidence | ConvertTo-Json -Depth 4
    throw "Windows 11 is required; detected $($os.Caption) build $build."
}
if ($RequireInteractive -and -not $interactive) {
    $evidence.status = "failed"
    $evidence | ConvertTo-Json -Depth 4
    throw "An interactive signed-in desktop session is required."
}
$evidence | ConvertTo-Json -Depth 4

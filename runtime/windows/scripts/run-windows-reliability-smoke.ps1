[CmdletBinding()]
param(
    [string]$RuntimePath = "",

    [ValidateRange(1, 100)]
    [int]$ActionIterations = 1,

    [string]$RealApp = "",

    [string]$RealAppTitle = "",

    [switch]$VerifyRealAppForegroundActivation,

    [switch]$DisplayOnly
)

$ErrorActionPreference = "Stop"
$pluginRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
if ([string]::IsNullOrWhiteSpace($RuntimePath)) {
    $RuntimePath = Join-Path $pluginRoot "runtime\bin\win32-x64\open-computer-use.exe"
}
$RuntimePath = [System.IO.Path]::GetFullPath($RuntimePath)
if (-not (Test-Path -LiteralPath $RuntimePath -PathType Leaf)) {
    throw "Windows runtime not found: $RuntimePath"
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DSHDesktopOperatorDisplayProbe {
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [DllImport("user32.dll")]
    public static extern IntPtr MonitorFromPoint(POINT point, uint flags);

    [DllImport("shcore.dll")]
    public static extern int GetDpiForMonitor(IntPtr monitor, int dpiType, out uint dpiX, out uint dpiY);

    [DllImport("shcore.dll")]
    public static extern int SetProcessDpiAwareness(int awareness);
}
"@

try {
    [void][DSHDesktopOperatorDisplayProbe]::SetProcessDpiAwareness(2)
} catch {
}
Add-Type -AssemblyName System.Windows.Forms

function Get-DisplayTopology {
    $displays = foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $center = New-Object DSHDesktopOperatorDisplayProbe+POINT
        $center.X = $screen.Bounds.Left + [int]($screen.Bounds.Width / 2)
        $center.Y = $screen.Bounds.Top + [int]($screen.Bounds.Height / 2)
        $monitor = [DSHDesktopOperatorDisplayProbe]::MonitorFromPoint($center, 2)
        [uint32]$dpiX = 96
        [uint32]$dpiY = 96
        try {
            if ([DSHDesktopOperatorDisplayProbe]::GetDpiForMonitor($monitor, 0, [ref]$dpiX, [ref]$dpiY) -ne 0) {
                $dpiX = 96
                $dpiY = 96
            }
        } catch {
            $dpiX = 96
            $dpiY = 96
        }
        [pscustomobject]@{
            deviceName = $screen.DeviceName
            primary = $screen.Primary
            bounds = [pscustomobject]@{
                x = $screen.Bounds.X
                y = $screen.Bounds.Y
                width = $screen.Bounds.Width
                height = $screen.Bounds.Height
            }
            dpiX = $dpiX
            dpiY = $dpiY
            scalePercent = [int][math]::Round(($dpiX / 96.0) * 100)
        }
    }
    return @($displays)
}

function Invoke-Smoke([string]$ScriptName, [hashtable]$Arguments = @{}) {
    $scriptPath = Join-Path $PSScriptRoot $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Smoke script not found: $scriptPath"
    }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $raw = & $scriptPath @Arguments | Out-String
    $stopwatch.Stop()
    try {
        $result = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "$ScriptName returned invalid JSON: $raw"
    }
    if ($result.status -ne "passed") {
        throw "$ScriptName did not report a passing result: $raw"
    }
    return [pscustomobject]@{
        script = $ScriptName
        durationMs = $stopwatch.ElapsedMilliseconds
        result = $result
    }
}

$startedAt = [DateTime]::UtcNow
$displays = @(Get-DisplayTopology)
$results = @()
if (-not $DisplayOnly) {
    $results += Invoke-Smoke "run-windows-capture-smoke.ps1" @{ RuntimePath = $RuntimePath }
    $results += Invoke-Smoke "run-windows-modal-smoke.ps1" @{ RuntimePath = $RuntimePath }
    for ($iteration = 1; $iteration -le $ActionIterations; $iteration++) {
        $result = Invoke-Smoke "run-windows-action-smoke.ps1" @{ RuntimePath = $RuntimePath }
        $result | Add-Member -NotePropertyName iteration -NotePropertyValue $iteration
        $results += $result
    }

    $negativeDisplay = $displays | Where-Object { $_.bounds.x -lt 0 -or $_.bounds.y -lt 0 } | Select-Object -First 1
    if ($null -ne $negativeDisplay) {
        $negativeLeft = $negativeDisplay.bounds.x + [math]::Min(80, [math]::Max(0, $negativeDisplay.bounds.width - 520))
        $negativeTop = $negativeDisplay.bounds.y + [math]::Min(80, [math]::Max(0, $negativeDisplay.bounds.height - 320))
        $negativeResult = Invoke-Smoke "run-windows-action-smoke.ps1" @{
            RuntimePath = $RuntimePath
            FixtureLeft = $negativeLeft
            FixtureTop = $negativeTop
        }
        $negativeResult | Add-Member -NotePropertyName coverage -NotePropertyValue "negative-coordinate-display"
        if (-not $negativeResult.result.negativeCoordinateFixture) {
            throw "Negative-coordinate fixture did not report a negative physical-screen origin."
        }
        $results += $negativeResult
    }
}

if (-not $DisplayOnly -and -not [string]::IsNullOrWhiteSpace($RealApp)) {
    $realAppArguments = @{
        App = $RealApp
        RuntimePath = $RuntimePath
        VerifyCurrentForegroundActivation = $VerifyRealAppForegroundActivation
    }
    if (-not [string]::IsNullOrWhiteSpace($RealAppTitle)) {
        $realAppArguments.Title = $RealAppTitle
    }
    $results += Invoke-Smoke "run-windows-window-smoke.ps1" $realAppArguments
}

$scales = @($displays | ForEach-Object { $_.scalePercent } | Sort-Object -Unique)
$hasNegativeCoordinates = @($displays | Where-Object { $_.bounds.x -lt 0 -or $_.bounds.y -lt 0 }).Count -gt 0
[pscustomobject]@{
    status = "passed"
    startedAtUtc = $startedAt.ToString("o")
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
    runtimePath = $RuntimePath
    displayOnly = [bool]$DisplayOnly
    actionIterations = $ActionIterations
    displayCoverage = [pscustomobject]@{
        displayCount = $displays.Count
        hasNegativeCoordinates = $hasNegativeCoordinates
        observedScalePercents = $scales
        mixedDpiObserved = $scales.Count -gt 1
        physicalNegativeCoordinateActionVerified = @($results | Where-Object { $_.coverage -eq "negative-coordinate-display" }).Count -gt 0
        displays = $displays
    }
    deterministicSuites = $results
    realAppChecked = -not [string]::IsNullOrWhiteSpace($RealApp)
} | ConvertTo-Json -Depth 12

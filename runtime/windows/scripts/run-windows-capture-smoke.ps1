[CmdletBinding()]
param(
    [string]$RuntimePath = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class OCUCaptureSmokeWin32 {
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int command);
}
"@

$pluginRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
if ([string]::IsNullOrWhiteSpace($RuntimePath)) {
    $RuntimePath = Join-Path $pluginRoot "runtime\bin\win32-x64\open-computer-use.exe"
}
$RuntimePath = [System.IO.Path]::GetFullPath($RuntimePath)
if (-not (Test-Path -LiteralPath $RuntimePath -PathType Leaf)) {
    throw "Windows runtime not found: $RuntimePath"
}

$targetTitle = "OCU capture target $([guid]::NewGuid().ToString('N'))"
$occluderTitle = "OCU capture occluder $([guid]::NewGuid().ToString('N'))"
$fixtureFile = Join-Path ([System.IO.Path]::GetTempPath()) ("open-computer-use-capture-fixture-" + [guid]::NewGuid().ToString("N") + ".ps1")
$fixtureProcess = $null
$mcpProcess = $null

$fixtureSource = @'
param(
    [Parameter(Mandatory = $true)][string]$TargetTitle,
    [Parameter(Mandatory = $true)][string]$OccluderTitle
)
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

function New-ColorWindow([string]$Title, $Color, [bool]$Topmost) {
    $window = New-Object System.Windows.Forms.Form
    $window.Text = $Title
    $window.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $window.Location = New-Object System.Drawing.Point(120, 120)
    $window.Size = New-Object System.Drawing.Size(520, 320)
    $window.Topmost = $Topmost
    $window.BackColor = $Color
    return $window
}

$target = New-ColorWindow $TargetTitle ([System.Drawing.Color]::Magenta) $false
$occluder = New-ColorWindow $OccluderTitle ([System.Drawing.Color]::Lime) $true
$target.Show()
$occluder.Show()
$occluder.Activate()
[System.Windows.Forms.Application]::Run($occluder)
'@

function Start-McpProcess {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:RuntimePath
    $startInfo.Arguments = "mcp"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.EnvironmentVariables["OPEN_COMPUTER_USE_WINDOWS_VISUAL_INDICATOR"] = "0"
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Could not start MCP runtime" }
    return $process
}

$nextRequestID = 1
function Invoke-McpRequest([string]$Method, $Params) {
    $requestID = $script:nextRequestID
    $script:nextRequestID++
    $request = [ordered]@{ jsonrpc = "2.0"; id = $requestID; method = $Method }
    if ($null -ne $Params) { $request.params = $Params }
    $script:mcpProcess.StandardInput.WriteLine(($request | ConvertTo-Json -Compress -Depth 30))
    $script:mcpProcess.StandardInput.Flush()
    $readTask = $script:mcpProcess.StandardOutput.ReadLineAsync()
    if (-not $readTask.Wait(20000)) {
        throw "MCP request timed out after 20 seconds: id=$requestID method=$Method"
    }
    $line = $readTask.Result
    if ([string]::IsNullOrWhiteSpace($line)) {
        throw "MCP runtime returned no response: id=$requestID method=$Method"
    }
    $response = $line | ConvertFrom-Json
    if ($null -ne $response.error) {
        throw "MCP request failed: $($response.error.message)"
    }
    return $response.result
}

function Invoke-ComputerUseTool([string]$Name, $Arguments) {
    return Invoke-McpRequest "tools/call" @{ name = $Name; arguments = $Arguments }
}

try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($fixtureFile, $fixtureSource, $utf8NoBom)
    $fixtureStartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $fixtureStartInfo.FileName = "powershell.exe"
    $fixtureStartInfo.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$fixtureFile`" -TargetTitle `"$targetTitle`" -OccluderTitle `"$occluderTitle`""
    $fixtureStartInfo.UseShellExecute = $false
    $fixtureStartInfo.CreateNoWindow = $true
    $fixtureProcess = [System.Diagnostics.Process]::Start($fixtureStartInfo)
    if ($null -eq $fixtureProcess) { throw "Could not start capture fixture" }

    $mcpProcess = Start-McpProcess
    [void](Invoke-McpRequest "initialize" @{ protocolVersion = "2025-03-26"; capabilities = @{}; clientInfo = @{ name = "windows-capture-smoke"; version = "1" } })

    $window = $null
    for ($attempt = 0; $attempt -lt 20 -and $null -eq $window; $attempt++) {
        Start-Sleep -Milliseconds 200
        $resolved = Invoke-ComputerUseTool "get_window" @{ app = "powershell"; title = $targetTitle }
        if (-not $resolved.isError) {
            $window = $resolved.content[0].text | ConvertFrom-Json
        }
    }
    if ($null -eq $window) { throw "Capture target window did not become available" }

    $observed = Invoke-ComputerUseTool "get_window_state" @{ window = $window; text_limit = 100; max_tree_nodes = 50; max_tree_depth = 8 }
    if ($observed.isError) { throw "get_window_state failed: $($observed.content[0].text)" }
    $text = [string]$observed.content[0].text
    if ($text -notmatch "(?m)^Capture:\s+method=windows-graphics-capture.+occlusionIndependent=true") {
        throw "Occluded target did not report the window content capture path: $text"
    }
    $image = @($observed.content | Where-Object { $_.type -eq "image" } | Select-Object -First 1)[0]
    if ($null -eq $image -or [string]::IsNullOrWhiteSpace($image.data)) {
        throw "get_window_state did not return image content"
    }

    [void][OCUCaptureSmokeWin32]::ShowWindowAsync([IntPtr][long]$window.hwnd, 6)
    Start-Sleep -Milliseconds 300
    $minimized = Invoke-ComputerUseTool "get_window_state" @{ window = $window; text_limit = 100; max_tree_nodes = 50; max_tree_depth = 8 }
    if ($minimized.isError) { throw "minimized get_window_state failed: $($minimized.content[0].text)" }
    $minimizedText = [string]$minimized.content[0].text
    if ($minimizedText -notmatch '"isMinimized":true' -or $minimizedText -notmatch 'Capture:\s+method=unavailable' -or $minimizedText -notmatch 'window_minimized_activate_window_required') {
        throw "Minimized target was not reported as an explicit non-capturable state: $minimizedText"
    }

    $activated = Invoke-ComputerUseTool "activate_window" @{ window = $window }
    if ($activated.isError) { throw "activate_window did not restore minimized target: $($activated.content[0].text)" }
    $restored = Invoke-ComputerUseTool "get_window_state" @{ window = $window; text_limit = 100; max_tree_nodes = 50; max_tree_depth = 8 }
    if ($restored.isError) { throw "restored get_window_state failed: $($restored.content[0].text)" }
    $restoredText = [string]$restored.content[0].text
    if ($restoredText -notmatch '(?m)^Capture:\s+method=windows-graphics-capture.+coordinateSpace=physical-screen-pixels.+dpiAwareness=per-monitor-v2') {
        throw "Restored target did not return a DPI-aware WGC snapshot: $restoredText"
    }

    $bytes = [Convert]::FromBase64String([string]$image.data)
    $stream = New-Object System.IO.MemoryStream(,$bytes)
    $bitmap = [System.Drawing.Bitmap]::FromStream($stream)
    try {
        $sample = $bitmap.GetPixel([int]($bitmap.Width / 2), [int]($bitmap.Height / 2))
        $targetVisible = $sample.R -ge 200 -and $sample.B -ge 200 -and $sample.G -le 80
        if (-not $targetVisible) {
            throw "Occluded capture sampled RGB($($sample.R),$($sample.G),$($sample.B)); expected target magenta rather than occluder lime"
        }
        [pscustomobject]@{
            status = "passed"
            captureMethod = "windows-graphics-capture"
            occlusionIndependent = $true
            minimizedCaptureRejected = $true
            minimizedRestoreVerified = $true
            targetHwnd = $window.hwnd
            sampledRgb = @($sample.R, $sample.G, $sample.B)
            imageWidth = $bitmap.Width
            imageHeight = $bitmap.Height
            dpi = [int]([regex]::Match($restoredText, 'dpi=(\d+)').Groups[1].Value)
            dpiAwareness = "per-monitor-v2"
        } | ConvertTo-Json -Depth 5
    } finally {
        $bitmap.Dispose()
        $stream.Dispose()
    }
} finally {
    if ($null -ne $mcpProcess -and -not $mcpProcess.HasExited) {
        try { $mcpProcess.StandardInput.Close() } catch {}
        if (-not $mcpProcess.WaitForExit(1000)) { $mcpProcess.Kill() }
    }
    if ($null -ne $fixtureProcess -and -not $fixtureProcess.HasExited) {
        Stop-Process -Id $fixtureProcess.Id -Force
    }
    if (Test-Path -LiteralPath $fixtureFile) {
        Remove-Item -LiteralPath $fixtureFile -Force
    }
}

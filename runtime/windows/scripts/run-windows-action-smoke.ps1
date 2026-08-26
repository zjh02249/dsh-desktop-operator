[CmdletBinding()]
param(
    [string]$RuntimePath = ""
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

$fixtureTitle = "OCU DSH action smoke $([guid]::NewGuid().ToString('N'))"
$fixtureFile = Join-Path ([System.IO.Path]::GetTempPath()) ("open-computer-use-fixture-" + [guid]::NewGuid().ToString("N") + ".ps1")
$fixtureProcess = $null
$mcpProcess = $null

$fixtureSource = @'
param([Parameter(Mandatory = $true)][string]$Title)
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase

$window = New-Object System.Windows.Window
$window.Title = $Title
$window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
$window.Left = 80
$window.Top = 80
$window.Width = 440
$window.Height = 240

$canvas = New-Object System.Windows.Controls.Canvas

$textBox = New-Object System.Windows.Controls.TextBox
$textBox.Name = "SmokeInput"
[System.Windows.Automation.AutomationProperties]::SetName($textBox, "Smoke input")
$textBox.Width = 360
$textBox.Height = 30
[System.Windows.Controls.Canvas]::SetLeft($textBox, 24)
[System.Windows.Controls.Canvas]::SetTop($textBox, 24)

$button = New-Object System.Windows.Controls.Button
$button.Name = "SmokeApply"
$button.Content = "Apply"
[System.Windows.Automation.AutomationProperties]::SetName($button, "Smoke apply")
$button.Width = 120
$button.Height = 34
[System.Windows.Controls.Canvas]::SetLeft($button, 24)
[System.Windows.Controls.Canvas]::SetTop($button, 70)

$status = New-Object System.Windows.Controls.TextBlock
$status.Name = "SmokeStatus"
$status.Text = "idle"
$status.Width = 360
$status.Height = 24
[System.Windows.Controls.Canvas]::SetLeft($status, 24)
[System.Windows.Controls.Canvas]::SetTop($status, 122)

$button.Add_Click({ $status.Text = "clicked:" + $textBox.Text })
$canvas.Children.Add($textBox) | Out-Null
$canvas.Children.Add($button) | Out-Null
$canvas.Children.Add($status) | Out-Null
$window.Content = $canvas
$window.Add_KeyDown({ if ($_.Key -eq [System.Windows.Input.Key]::Enter) { $button.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent))) } })
[void]$window.ShowDialog()
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
    $startInfo.EnvironmentVariables["OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS"] = "1"
    $startInfo.EnvironmentVariables["OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK"] = "1"
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
    $json = $request | ConvertTo-Json -Compress -Depth 30
    $script:mcpProcess.StandardInput.WriteLine($json)
    $script:mcpProcess.StandardInput.Flush()
    Write-Verbose "Waiting for MCP response id=$requestID method=$Method"
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
    Write-Verbose "Calling Computer Use tool: $Name"
    return Invoke-McpRequest "tools/call" @{ name = $Name; arguments = $Arguments }
}

function Assert-ToolSuccess($Result, [string]$Name) {
    if ($null -eq $Result -or $Result.isError) {
        $message = if ($null -ne $Result.content) { $Result.content[0].text } else { "missing result" }
        throw "$Name failed: $message"
    }
}

function Get-SnapshotTokens($Result) {
    $text = [string]$Result.content[0].text
    $observationMatch = [regex]::Match($text, "(?m)^ObservationID:\s*(?<value>\S+)\s*$")
    $screenshotMatch = [regex]::Match($text, "(?m)^ScreenshotID:\s*(?<value>\S+)\s*$")
    if (-not $observationMatch.Success -or -not $screenshotMatch.Success) {
        throw "Snapshot IDs missing from tool result"
    }
    [pscustomobject]@{
        Text = $text
        ObservationID = $observationMatch.Groups["value"].Value
        ScreenshotID = $screenshotMatch.Groups["value"].Value
    }
}

function Get-Element([string]$SnapshotText, [string]$AccessibleName) {
    $name = [regex]::Escape($AccessibleName)
    $match = [regex]::Match($SnapshotText, "(?m)^\s*(?<index>\d+)\s+[^\r\n]*$name[^\r\n]*$")
    if (-not $match.Success) {
        Write-Verbose "Accessibility snapshot:`n$SnapshotText"
        throw "Element '$AccessibleName' was not found in the accessibility tree"
    }
    $frame = [regex]::Match($match.Value, "Frame:\s*\{x:\s*(?<x>-?\d+),\s*y:\s*(?<y>-?\d+),\s*width:\s*(?<width>\d+),\s*height:\s*(?<height>\d+)\}")
    $value = [regex]::Match($match.Value, "\sValue:\s*(?<value>.*?)\s+Secondary Actions:")
    [pscustomobject]@{
        Index = $match.Groups["index"].Value
        Value = if ($value.Success) { $value.Groups["value"].Value } else { "" }
        X = if ($frame.Success) { [int]$frame.Groups["x"].Value } else { $null }
        Y = if ($frame.Success) { [int]$frame.Groups["y"].Value } else { $null }
        Width = if ($frame.Success) { [int]$frame.Groups["width"].Value } else { $null }
        Height = if ($frame.Success) { [int]$frame.Groups["height"].Value } else { $null }
    }
}

try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($fixtureFile, $fixtureSource, $utf8NoBom)
    $fixtureStartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $fixtureStartInfo.FileName = "powershell.exe"
    $fixtureStartInfo.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$fixtureFile`" -Title `"$fixtureTitle`""
    $fixtureStartInfo.UseShellExecute = $false
    $fixtureStartInfo.CreateNoWindow = $true
    $fixtureProcess = [System.Diagnostics.Process]::Start($fixtureStartInfo)
    if ($null -eq $fixtureProcess) { throw "Could not start WinForms fixture" }

    $mcpProcess = Start-McpProcess
    [void](Invoke-McpRequest "initialize" @{ protocolVersion = "2025-03-26"; capabilities = @{}; clientInfo = @{ name = "windows-action-smoke"; version = "1" } })

    $window = $null
    for ($attempt = 0; $attempt -lt 12 -and $null -eq $window; $attempt++) {
        Start-Sleep -Milliseconds 200
        $resolved = Invoke-ComputerUseTool "get_window" @{ app = "powershell"; title = $fixtureTitle }
        if (-not $resolved.isError) { $window = $resolved.content[0].text | ConvertFrom-Json }
    }
    if ($null -eq $window) { throw "Fixture window did not become available" }

    $activated = Invoke-ComputerUseTool "activate_window" @{ window = $window }
    Assert-ToolSuccess $activated "activate_window"

    $observed = Invoke-ComputerUseTool "get_window_state" @{ window = $window; text_limit = 500; max_tree_nodes = 200; max_tree_depth = 24 }
    Assert-ToolSuccess $observed "get_window_state"
    $initial = Get-SnapshotTokens $observed
    $inputElement = Get-Element $initial.Text "Smoke input"

    $setValue = Invoke-ComputerUseTool "set_value" @{
        window = $window
        observation_id = $initial.ObservationID
        element_index = $inputElement.Index
        value = "alpha"
    }
    Assert-ToolSuccess $setValue "set_value"
    $afterSet = Get-SnapshotTokens $setValue
    if ($afterSet.Text -notmatch "alpha") { throw "set_value post-action snapshot did not contain alpha" }

    $staleCoordinate = Invoke-ComputerUseTool "click" @{
        window = $window
        screenshot_id = $initial.ScreenshotID
        x = 30
        y = 30
    }
    if (-not $staleCoordinate.isError -or $staleCoordinate.content[0].text -notmatch "screenshot_id does not match") {
        throw "A stale screenshot_id was not rejected before coordinate input"
    }

    $buttonElement = Get-Element $afterSet.Text "Smoke apply"
    if ($null -eq $buttonElement.X) { throw "Smoke apply did not expose a coordinate frame" }
    Write-Verbose ("Smoke apply frame: x={0} y={1} width={2} height={3}" -f $buttonElement.X, $buttonElement.Y, $buttonElement.Width, $buttonElement.Height)
    $coordinateClick = Invoke-ComputerUseTool "click" @{
        window = $window
        screenshot_id = $afterSet.ScreenshotID
        x = $buttonElement.X + [int]($buttonElement.Width / 2)
        y = $buttonElement.Y + [int]($buttonElement.Height / 2)
        click_method = "app_post"
    }
    Assert-ToolSuccess $coordinateClick "coordinate click"
    $afterCoordinateClick = Get-SnapshotTokens $coordinateClick
    if ($afterCoordinateClick.Text -notmatch "clicked:alpha") {
        Write-Verbose "Coordinate click snapshot:`n$($afterCoordinateClick.Text)"
        throw "Coordinate click post-action state was not observed"
    }

    $inputElement = Get-Element $afterCoordinateClick.Text "Smoke input"
    $focusInput = Invoke-ComputerUseTool "click" @{
        window = $window
        observation_id = $afterCoordinateClick.ObservationID
        element_index = $inputElement.Index
        click_method = "accessibility"
    }
    Assert-ToolSuccess $focusInput "focus input"
    $afterFocus = Get-SnapshotTokens $focusInput

    $typed = Invoke-ComputerUseTool "type_text" @{
        window = $window
        observation_id = $afterFocus.ObservationID
        text = "Z9"
    }
    Assert-ToolSuccess $typed "type_text"
    $afterType = Get-SnapshotTokens $typed
    $typedInput = Get-Element $afterType.Text "Smoke input"
    if ($typedInput.Value -notmatch "Z9") {
        Write-Verbose "type_text snapshot:`n$($afterType.Text)"
        throw "type_text post-action snapshot did not contain the typed text"
    }

    $pressed = Invoke-ComputerUseTool "press_key" @{
        window = $window
        observation_id = $afterType.ObservationID
        key = "Return"
    }
    Assert-ToolSuccess $pressed "press_key"
    $afterPress = Get-SnapshotTokens $pressed
    if ($afterPress.Text -notmatch ([regex]::Escape("clicked:$($typedInput.Value)"))) { throw "press_key post-action state was not observed" }

    [pscustomobject]@{
        status = "passed"
        app = $window.appId
        pid = $window.pid
        hwnd = $window.hwnd
        staleScreenshotRejected = $true
        setValueVerified = $true
        coordinateClickVerified = $true
        typeTextVerified = $true
        pressKeyVerified = $true
    } | ConvertTo-Json -Depth 5
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

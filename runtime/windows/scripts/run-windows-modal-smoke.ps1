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

$token = [guid]::NewGuid().ToString("N")
$mainTitle = "OCU modal owner $token"
$dialogTitle = "OCU modal dialog $token"
$fixtureFile = Join-Path ([System.IO.Path]::GetTempPath()) ("open-computer-use-modal-fixture-$token.ps1")
$fixtureProcess = $null
$mcpProcess = $null

$fixtureSource = @'
param(
    [Parameter(Mandatory = $true)][string]$MainTitle,
    [Parameter(Mandatory = $true)][string]$DialogTitle
)
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

$main = New-Object System.Windows.Forms.Form
$main.Text = $MainTitle
$main.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$main.Location = New-Object System.Drawing.Point(120, 120)
$main.Size = New-Object System.Drawing.Size(480, 260)

$label = New-Object System.Windows.Forms.Label
$label.Text = "owner-window"
$label.AutoSize = $true
$label.Location = New-Object System.Drawing.Point(24, 24)
$main.Controls.Add($label)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 350
$timer.Add_Tick({
    $timer.Stop()
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $DialogTitle
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.Size = New-Object System.Drawing.Size(360, 180)
    $dialog.ControlBox = $false
    $dialogLabel = New-Object System.Windows.Forms.Label
    $dialogLabel.Text = "blocking-modal"
    $dialogLabel.AutoSize = $true
    $dialogLabel.Location = New-Object System.Drawing.Point(24, 24)
    $dialog.Controls.Add($dialogLabel)
    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = "Close dialog"
    $closeButton.Location = New-Object System.Drawing.Point(220, 90)
    $closeButton.Size = New-Object System.Drawing.Size(100, 30)
    $closeButton.Add_Click({ $dialog.Close() })
    $dialog.Controls.Add($closeButton)
    [void]$dialog.ShowDialog($main)
})
$main.Add_Shown({ $timer.Start() })
[void][System.Windows.Forms.Application]::Run($main)
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
    $startInfo.EnvironmentVariables["OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS"] = "1"
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

function Assert-ToolSuccess($Result, [string]$Name) {
    if ($null -eq $Result -or $Result.isError) {
        $message = if ($null -ne $Result.content) { $Result.content[0].text } else { "missing result" }
        throw "$Name failed: $message"
    }
}

try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($fixtureFile, $fixtureSource, $utf8NoBom)
    $fixtureStartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $fixtureStartInfo.FileName = "powershell.exe"
    $fixtureStartInfo.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$fixtureFile`" -MainTitle `"$mainTitle`" -DialogTitle `"$dialogTitle`""
    $fixtureStartInfo.UseShellExecute = $false
    $fixtureStartInfo.CreateNoWindow = $true
    $fixtureProcess = [System.Diagnostics.Process]::Start($fixtureStartInfo)
    if ($null -eq $fixtureProcess) { throw "Could not start modal fixture" }

    $mcpProcess = Start-McpProcess
    [void](Invoke-McpRequest "initialize" @{ protocolVersion = "2025-03-26"; capabilities = @{}; clientInfo = @{ name = "windows-modal-smoke"; version = "1" } })

    $ownerWindow = $null
    $modalWindow = $null
    for ($attempt = 0; $attempt -lt 30 -and ($null -eq $ownerWindow -or $null -eq $modalWindow); $attempt++) {
        Start-Sleep -Milliseconds 200
        if ($null -eq $ownerWindow) {
            $ownerResult = Invoke-ComputerUseTool "get_window" @{ app = "powershell"; title = $mainTitle }
            if (-not $ownerResult.isError) { $ownerWindow = $ownerResult.content[0].text | ConvertFrom-Json }
        }
        if ($null -eq $modalWindow) {
            $modalResult = Invoke-ComputerUseTool "get_window" @{ app = "powershell"; title = $dialogTitle }
            if (-not $modalResult.isError) { $modalWindow = $modalResult.content[0].text | ConvertFrom-Json }
        }
    }
    if ($null -eq $ownerWindow -or $null -eq $modalWindow) {
        throw "Fixture owner or modal window did not become available"
    }
    if (-not $modalWindow.isModal -or [string]$modalWindow.ownerHwnd -ne [string]$ownerWindow.hwnd) {
        throw "Modal WindowRef did not identify its owner: $($modalWindow | ConvertTo-Json -Compress)"
    }

    $ownerState = Invoke-ComputerUseTool "get_window_state" @{ window = $ownerWindow; text_limit = 500; max_tree_nodes = 200; max_tree_depth = 24 }
    Assert-ToolSuccess $ownerState "get_window_state owner"
    $ownerText = [string]$ownerState.content[0].text
    if ($ownerText -notmatch "(?m)^ModalWindows:" -or $ownerText -notmatch [regex]::Escape($dialogTitle)) {
        throw "Owner snapshot did not expose the blocking modal candidate"
    }

    $blockedActivation = Invoke-ComputerUseTool "activate_window" @{ window = $ownerWindow }
    if (-not $blockedActivation.isError -or $blockedActivation.content[0].text -notmatch "modal_window_required" -or $blockedActivation.content[0].text -notmatch [regex]::Escape($dialogTitle)) {
        throw "Owner activation was not rejected with its modal candidate"
    }

    $activatedModal = Invoke-ComputerUseTool "activate_window" @{ window = $modalWindow }
    Assert-ToolSuccess $activatedModal "activate_window modal"
    $modalState = Invoke-ComputerUseTool "get_window_state" @{ window = $modalWindow; text_limit = 500; max_tree_nodes = 200; max_tree_depth = 24 }
    Assert-ToolSuccess $modalState "get_window_state modal"
    if ([string]$modalState.content[0].text -notmatch "blocking-modal") {
        throw "Modal snapshot did not expose its fixture content"
    }

    $modalText = [string]$modalState.content[0].text
    $observationMatch = [regex]::Match($modalText, "(?m)^ObservationID:\s*(?<value>\S+)\s*$")
    $closeMatch = [regex]::Match($modalText, "(?m)^\s*(?<index>\d+)\s+[^\r\n]*Close dialog[^\r\n]*$")
    if (-not $observationMatch.Success -or -not $closeMatch.Success) {
        throw "Modal snapshot did not expose its close action and observation id"
    }
    $closedModal = Invoke-ComputerUseTool "click" @{
        window = $modalWindow
        observation_id = $observationMatch.Groups["value"].Value
        element_index = $closeMatch.Groups["index"].Value
        action_intent = @{ kind = "dismiss"; summary = "Close the test modal dialog" }
        expected_postcondition = @{ type = "window_closed" }
    }
    Assert-ToolSuccess $closedModal "close modal"
    $closedText = [string]$closedModal.content[0].text
    if ($closedText -notmatch "WindowClosed: true" -or $closedText -notmatch "ActionStatus: applied" -or $closedText -notmatch "Postcondition: type=window_closed satisfied=true") {
        throw "Closed modal was not verified through the window_closed postcondition"
    }

    [pscustomobject]@{
        status = "passed"
        ownerHwnd = $ownerWindow.hwnd
        modalHwnd = $modalWindow.hwnd
        ownerRejected = $true
        modalCandidateExposed = $true
        modalActivated = $true
        modalCloseVerified = $true
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

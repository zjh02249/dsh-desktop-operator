[CmdletBinding()]
param(
    [string]$RuntimePath = "",

    [string]$MatrixPath = "",

    [switch]$RequireAllCategories
)

$ErrorActionPreference = "Stop"
$pluginRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
if ([string]::IsNullOrWhiteSpace($RuntimePath)) {
    $RuntimePath = Join-Path $pluginRoot "runtime\bin\win32-x64\open-computer-use.exe"
}
if ([string]::IsNullOrWhiteSpace($MatrixPath)) {
    $MatrixPath = Join-Path $pluginRoot "quality\windows-app-matrix.json"
}
$RuntimePath = [System.IO.Path]::GetFullPath($RuntimePath)
$MatrixPath = [System.IO.Path]::GetFullPath($MatrixPath)
if (-not (Test-Path -LiteralPath $RuntimePath -PathType Leaf)) { throw "Windows runtime not found: $RuntimePath" }
if (-not (Test-Path -LiteralPath $MatrixPath -PathType Leaf)) { throw "Quality matrix not found: $MatrixPath" }
$matrix = [System.IO.File]::ReadAllText($MatrixPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json

$mcpProcess = $null
$nextRequestID = 1

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
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Could not start MCP runtime" }
    return $process
}

function Invoke-McpRequest([string]$Method, $Params) {
    $requestID = $script:nextRequestID
    $script:nextRequestID++
    $request = [ordered]@{ jsonrpc = "2.0"; id = $requestID; method = $Method }
    if ($null -ne $Params) { $request.params = $Params }
    $json = ($request | ConvertTo-Json -Compress -Depth 30) + [Environment]::NewLine
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $script:mcpProcess.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $script:mcpProcess.StandardInput.BaseStream.Flush()
    $readTask = $script:mcpProcess.StandardOutput.ReadLineAsync()
    if (-not $readTask.Wait(30000)) { throw "MCP request timed out: id=$requestID method=$Method" }
    $line = $readTask.Result
    if ([string]::IsNullOrWhiteSpace($line)) { throw "MCP runtime returned no response: id=$requestID method=$Method" }
    $response = $line | ConvertFrom-Json
    if ($null -ne $response.error) { throw "MCP request failed: $($response.error.message)" }
    return $response.result
}

function Invoke-ComputerUseTool([string]$Name, $Arguments) {
    return Invoke-McpRequest "tools/call" @{ name = $Name; arguments = $Arguments }
}

function Get-ToolError($Result) {
    if ($null -eq $Result -or -not $Result.isError) { return "" }
    if ($null -ne $Result.content) { return [string]$Result.content[0].text }
    return "missing result"
}

function Get-SelectorArguments($Selector, $Window, [string]$ObservationID) {
    $arguments = @{ window = $Window; observation_id = $ObservationID; limit = 100 }
    foreach ($property in @("name", "automation_id", "value", "control_type", "class_name", "action")) {
        if ($null -ne $Selector.$property -and -not [string]::IsNullOrWhiteSpace([string]$Selector.$property)) {
            $arguments[$property] = [string]$Selector.$property
        }
    }
    return $arguments
}

function Test-Candidate($Candidate) {
    $resolved = Invoke-ComputerUseTool "get_window" @{ app = [string]$Candidate.app }
    $resolveError = Get-ToolError $resolved
    if (-not [string]::IsNullOrWhiteSpace($resolveError)) {
        return [pscustomobject]@{
            app = [string]$Candidate.app
            product = [string]$Candidate.product
            status = "not_available"
            reason = $resolveError
        }
    }
    $window = $resolved.content[0].text | ConvertFrom-Json
    $activated = Invoke-ComputerUseTool "activate_window" @{ window = $window }
    $activateError = Get-ToolError $activated
    if (-not [string]::IsNullOrWhiteSpace($activateError)) {
        return [pscustomobject]@{
            app = [string]$Candidate.app
            product = [string]$Candidate.product
            status = "failed"
            reason = $activateError
        }
    }
    $observed = Invoke-ComputerUseTool "get_window_state" @{
        window = $window
        text_limit = 1000
        max_tree_nodes = 3000
        max_tree_depth = 96
    }
    $observeError = Get-ToolError $observed
    if (-not [string]::IsNullOrWhiteSpace($observeError)) {
        return [pscustomobject]@{
            app = [string]$Candidate.app
            product = [string]$Candidate.product
            status = "failed"
            reason = $observeError
        }
    }
    $snapshotText = [string]$observed.content[0].text
    $observationMatch = [regex]::Match($snapshotText, "(?m)^ObservationID:\s*(?<value>\S+)\s*$")
    $captureMatch = [regex]::Match($snapshotText, "(?m)^Capture:\s+method=(?<method>\S+).+occlusionIndependent=(?<independent>true|false)")
    if (-not $observationMatch.Success -or -not $captureMatch.Success) {
        return [pscustomobject]@{
            app = [string]$Candidate.app
            product = [string]$Candidate.product
            status = "failed"
            reason = "Snapshot did not include observation and capture provenance."
        }
    }

    $selectorResults = @()
    $selectors = @($Candidate.selectors | Where-Object { $null -ne $_ })
    if ($selectors.Count -eq 0) {
        $selectors = @(
            [pscustomobject]@{ action = "SetValue"; minMatches = 0 },
            [pscustomobject]@{ action = "Invoke"; minMatches = 0 },
            [pscustomobject]@{ control_type = "Edit"; minMatches = 0 },
            [pscustomobject]@{ control_type = "Button"; minMatches = 0 }
        )
    }
    $semanticIndexes = @{}
    $selectorFailure = $false
    foreach ($selector in $selectors) {
        $arguments = Get-SelectorArguments $selector $window $observationMatch.Groups["value"].Value
        $found = Invoke-ComputerUseTool "find_elements" $arguments
        $findError = Get-ToolError $found
        if (-not [string]::IsNullOrWhiteSpace($findError)) {
            $selectorFailure = $true
            $selectorResults += [pscustomobject]@{ selector = $arguments; status = "failed"; matchCount = 0; reason = $findError }
            continue
        }
        $payload = $found.content[0].text | ConvertFrom-Json
        foreach ($element in @($payload.elements)) { $semanticIndexes[[string]$element.index] = $true }
        $minimum = if ($null -eq $selector.minMatches) { 1 } else { [int]$selector.minMatches }
        $passed = [int]$payload.matchCount -ge $minimum
        if (-not $passed) { $selectorFailure = $true }
        $selectorResults += [pscustomobject]@{
            selector = $arguments
            status = if ($passed) { "passed" } else { "failed" }
            matchCount = [int]$payload.matchCount
            minimum = $minimum
        }
    }
    if (@($Candidate.selectors | Where-Object { $null -ne $_ }).Count -eq 0 -and $semanticIndexes.Count -lt 1) {
        $selectorFailure = $true
    }
    return [pscustomobject]@{
        app = [string]$Candidate.app
        product = [string]$Candidate.product
        status = if ($selectorFailure) { "failed" } else { "passed" }
        pid = $window.pid
        hwnd = $window.hwnd
        title = $window.title
        captureMethod = $captureMatch.Groups["method"].Value
        occlusionIndependentCapture = $captureMatch.Groups["independent"].Value -eq "true"
        semanticElementCount = $semanticIndexes.Count
        selectors = $selectorResults
    }
}

try {
    $mcpProcess = Start-McpProcess
    [void](Invoke-McpRequest "initialize" @{ protocolVersion = "2025-03-26"; capabilities = @{}; clientInfo = @{ name = "windows-quality-matrix"; version = "1" } })
    $categories = @()
    foreach ($category in @($matrix.categories)) {
        $candidates = @($category.candidates | ForEach-Object { Test-Candidate $_ })
        $passedCount = @($candidates | Where-Object { $_.status -eq "passed" }).Count
        $availableCount = @($candidates | Where-Object { $_.status -ne "not_available" }).Count
        $categoryStatus = if ($passedCount -gt 0) { "passed" } elseif ($availableCount -eq 0) { "not_available" } else { "failed" }
        $categories += [pscustomobject]@{
            id = [string]$category.id
            framework = [string]$category.framework
            required = [bool]$category.required
            status = $categoryStatus
            candidates = $candidates
        }
    }
    $failedRequired = @($categories | Where-Object { $_.required -and $_.status -eq "failed" }).Count
    $unavailableRequired = @($categories | Where-Object { $_.required -and $_.status -eq "not_available" }).Count
    $summary = [pscustomobject]@{
        status = if ($failedRequired -gt 0) { "failed" } elseif ($unavailableRequired -gt 0) { "passed_with_gaps" } else { "passed" }
        generatedAtUtc = [DateTime]::UtcNow.ToString("o")
        host = [pscustomobject]@{
            os = [System.Environment]::OSVersion.VersionString
            version = [System.Environment]::OSVersion.Version.ToString()
            architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        }
        categories = $categories
    }
    $summary | ConvertTo-Json -Depth 15
    if ($summary.status -eq "failed" -or ($RequireAllCategories -and $summary.status -ne "passed")) {
        throw "Windows application quality matrix did not satisfy the required categories: $($summary.status)"
    }
} finally {
    if ($null -ne $mcpProcess -and -not $mcpProcess.HasExited) {
        try { $mcpProcess.StandardInput.Close() } catch {}
        if (-not $mcpProcess.WaitForExit(1000)) { $mcpProcess.Kill() }
    }
}

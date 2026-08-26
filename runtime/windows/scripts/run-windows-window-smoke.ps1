[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$App,

    [string]$Title = "",

    [string]$RuntimePath = "",

    [switch]$VerifyCurrentForegroundActivation
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

function Invoke-ComputerUseTool([string]$Tool, $Arguments) {
    $argumentsJson = $Arguments | ConvertTo-Json -Compress -Depth 12
    $argsFile = Join-Path ([System.IO.Path]::GetTempPath()) ("open-computer-use-smoke-" + [guid]::NewGuid().ToString("N") + ".json")
    $stdoutFile = Join-Path ([System.IO.Path]::GetTempPath()) ("open-computer-use-smoke-" + [guid]::NewGuid().ToString("N") + ".stdout")
    $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) ("open-computer-use-smoke-" + [guid]::NewGuid().ToString("N") + ".stderr")
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($argsFile, $argumentsJson, $utf8NoBom)
        $process = Start-Process -FilePath $script:RuntimePath -ArgumentList @("call", $Tool, "--args-file", $argsFile) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $raw = if (Test-Path -LiteralPath $stdoutFile) { [System.IO.File]::ReadAllText($stdoutFile, [System.Text.Encoding]::UTF8) } else { "" }
        $exitCode = $process.ExitCode
        try {
            $result = $raw | ConvertFrom-Json
        } catch {
            throw "$Tool returned invalid JSON (exit $exitCode): $raw"
        }
        [pscustomobject]@{ ExitCode = $exitCode; Result = $result }
    } finally {
        if (Test-Path -LiteralPath $argsFile) {
            Remove-Item -LiteralPath $argsFile -Force
        }
        foreach ($tempFile in @($stdoutFile, $stderrFile)) {
            if (Test-Path -LiteralPath $tempFile) {
                Remove-Item -LiteralPath $tempFile -Force
            }
        }
    }
}

function ConvertTo-JsonObjectArray([string]$JsonText) {
    $parsed = $JsonText | ConvertFrom-Json
    if ($parsed -is [System.Array]) {
        return @($parsed)
    }
    return @($parsed)
}

$listed = Invoke-ComputerUseTool "list_windows" @{ app = $App }
if ($listed.ExitCode -ne 0 -or $listed.Result.isError) {
    throw "list_windows failed: $($listed.Result.content[0].text)"
}
$windows = @(ConvertTo-JsonObjectArray $listed.Result.content[0].text)
if ($windows.Count -eq 0) { throw "list_windows returned no candidates for $App" }

$getArgs = @{ app = $App }
if (-not [string]::IsNullOrWhiteSpace($Title)) { $getArgs.title = $Title }
$resolved = Invoke-ComputerUseTool "get_window" $getArgs
if ($resolved.ExitCode -ne 0 -or $resolved.Result.isError) {
    throw "get_window failed: $($resolved.Result.content[0].text)"
}
$window = $resolved.Result.content[0].text | ConvertFrom-Json

$observed = Invoke-ComputerUseTool "get_window_state" @{
    window = $window
    text_limit = 200
    max_tree_nodes = 100
    max_tree_depth = 24
}
if ($observed.ExitCode -ne 0 -or $observed.Result.isError) {
    throw "get_window_state failed: $($observed.Result.content[0].text)"
}
if (-not ($observed.Result.content[0].text -like "*ObservationID:*$($window.generation)*")) {
    throw "get_window_state did not preserve the selected window generation"
}

$staleWindow = $window.PSObject.Copy()
$staleWindow.generation = "$($window.generation)-stale-smoke"
$stale = Invoke-ComputerUseTool "get_window_state" @{ window = $staleWindow }
if ($stale.ExitCode -eq 0 -or -not $stale.Result.isError -or $stale.Result.content[0].text -notlike "stale_window*") {
    throw "stale WindowRef was not rejected"
}

if ($VerifyCurrentForegroundActivation) {
    $all = Invoke-ComputerUseTool "list_windows" @{}
    if ($all.ExitCode -ne 0 -or $all.Result.isError) { throw "unfiltered list_windows failed" }
    $allWindows = @(ConvertTo-JsonObjectArray $all.Result.content[0].text)
    $foreground = $allWindows | Where-Object { $_.isForeground } | Select-Object -First 1
    if ($null -eq $foreground) { throw "No current foreground WindowRef was found" }
    $activated = Invoke-ComputerUseTool "activate_window" @{ window = $foreground }
    if ($activated.ExitCode -ne 0 -or $activated.Result.isError) {
        throw "activate_window failed: $($activated.Result.content[0].text)"
    }
}

[pscustomobject]@{
    status = "passed"
    app = $window.appId
    pid = $window.pid
    hwnd = $window.hwnd
    generation = $window.generation
    candidateCount = $windows.Count
    screenshotReturned = @($observed.Result.content | Where-Object { $_.type -eq "image" }).Count -gt 0
    foregroundActivationChecked = [bool]$VerifyCurrentForegroundActivation
} | ConvertTo-Json -Depth 5

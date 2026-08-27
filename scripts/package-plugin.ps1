[CmdletBinding()]
param(
    [string]$GoExecutable = "",

    [string]$OutputDirectory = "artifacts\package"
)

$ErrorActionPreference = "Stop"
$pluginRoot = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $PSScriptRoot "build-runtime.ps1"
$package = Get-Content -Raw -LiteralPath (Join-Path $pluginRoot "package.json") | ConvertFrom-Json
$architectures = @("amd64", "arm64")
$buildArguments = @{ Architecture = $architectures }

function Get-Sha256([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha256.ComputeHash($stream) | ForEach-Object { $_.ToString("X2") }) -join "")
    } finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}
if (-not [string]::IsNullOrWhiteSpace($GoExecutable)) {
    $buildArguments.GoExecutable = $GoExecutable
}

& $buildScript @buildArguments
if ($LASTEXITCODE -ne 0) { throw "Runtime build failed with exit code $LASTEXITCODE." }

Push-Location $pluginRoot
try {
    & node --test
    if ($LASTEXITCODE -ne 0) { throw "Plugin tests failed with exit code $LASTEXITCODE." }

    $pnpm = @(Get-Command pnpm -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($null -eq $pnpm) { throw "pnpm was not found." }
    $tar = @(Get-Command tar -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($null -eq $tar) { throw "tar was not found; it is required to verify the plugin archive." }

    $outputPath = if ([System.IO.Path]::IsPathRooted($OutputDirectory)) {
        [System.IO.Path]::GetFullPath($OutputDirectory)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $pluginRoot $OutputDirectory))
    }
    New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

    & $pnpm.Source pack --pack-destination $outputPath
    if ($LASTEXITCODE -ne 0) { throw "pnpm pack failed with exit code $LASTEXITCODE." }

    $archive = Get-ChildItem -LiteralPath $outputPath -Filter "*.tgz" -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $archive) { throw "pnpm pack produced no .tgz archive in $outputPath." }

    $entries = @(& $tar.Source -tf $archive.FullName)
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect package archive $($archive.FullName)." }
    $requiredEntries = @(
        "package/lib/index.js",
        "package/README.en.md",
        "package/CHANGELOG.md",
        "package/runtime/bin/runtime-manifest.json",
        "package/runtime/bin/win32-x64/open-computer-use.exe",
        "package/runtime/bin/win32-arm64/open-computer-use.exe",
        "package/runtime/windows/main.go",
        "package/runtime/windows/capture_helper.cs",
        "package/runtime/windows/indicator.ps1",
        "package/runtime/windows/runtime.ps1",
        "package/runtime/windows/scripts/run-windows-action-smoke.ps1",
        "package/runtime/windows/scripts/run-windows-capture-smoke.ps1",
        "package/runtime/windows/scripts/run-windows-modal-smoke.ps1",
        "package/runtime/windows/scripts/run-windows-window-smoke.ps1",
        "package/runtime/LICENSE.open-computer-use",
        "package/runtime/THIRD_PARTY_NOTICES.open-computer-use.md"
    )
    $missing = @($requiredEntries | Where-Object { $_ -notin $entries })
    if ($missing.Count -gt 0) {
        throw "Plugin archive is incomplete. Missing: $($missing -join ', ')"
    }

    $verificationRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dsh-computer-use-package-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Path $verificationRoot | Out-Null
        & $tar.Source -xf $archive.FullName -C $verificationRoot
        if ($LASTEXITCODE -ne 0) { throw "Could not extract package archive for runtime verification." }

        $packagedManifest = Get-Content -Raw -LiteralPath (Join-Path $verificationRoot "package\package.json") | ConvertFrom-Json
        if ($null -ne $packagedManifest.dependencies.'open-computer-use') {
            throw "Packaged plugin still depends on the external open-computer-use package."
        }

        $packagedRuntime = Join-Path $verificationRoot "package\runtime\bin\win32-x64\open-computer-use.exe"
        $runtimeVersion = [string](& $packagedRuntime --version)
        if ($LASTEXITCODE -ne 0 -or $runtimeVersion.Trim() -ne [string]$package.version) {
            throw "Packaged runtime version mismatch. Expected $($package.version), received '$runtimeVersion'."
        }

        $mcpRequests = @(
            '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"package-verifier","version":"1"}}}',
            '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}',
            '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
        )
        $previousIndicatorSetting = [Environment]::GetEnvironmentVariable(
            "OPEN_COMPUTER_USE_WINDOWS_VISUAL_INDICATOR",
            [EnvironmentVariableTarget]::Process
        )
        try {
            [Environment]::SetEnvironmentVariable(
                "OPEN_COMPUTER_USE_WINDOWS_VISUAL_INDICATOR",
                "false",
                [EnvironmentVariableTarget]::Process
            )
            $rawResponses = (($mcpRequests -join "`n") + "`n") | & $packagedRuntime mcp
            $mcpExitCode = $LASTEXITCODE
        } finally {
            [Environment]::SetEnvironmentVariable(
                "OPEN_COMPUTER_USE_WINDOWS_VISUAL_INDICATOR",
                $previousIndicatorSetting,
                [EnvironmentVariableTarget]::Process
            )
        }
        if ($mcpExitCode -ne 0) {
            throw "Packaged MCP runtime exited with code $mcpExitCode during archive verification."
        }
        $responses = @($rawResponses |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { $_ | ConvertFrom-Json })
        $initializeResponse = $responses | Where-Object { $_.id -eq 1 } | Select-Object -First 1
        $toolsResponse = $responses | Where-Object { $_.id -eq 2 } | Select-Object -First 1
        if ($null -eq $initializeResponse -or $null -eq $toolsResponse) {
            $responseIds = @($responses | ForEach-Object { [string]$_.id }) -join ", "
            throw "Packaged MCP runtime returned incomplete JSON-RPC responses. Received ids: $responseIds"
        }
        if ($null -ne $initializeResponse.error -or $null -ne $toolsResponse.error) {
            throw "Packaged MCP runtime returned a JSON-RPC error during archive verification."
        }
        if ($initializeResponse.result.protocolVersion -ne "2025-03-26") {
            throw "Packaged MCP runtime returned unexpected protocol version '$($initializeResponse.result.protocolVersion)'."
        }
        $toolNames = @($toolsResponse.result.tools | ForEach-Object { $_.name })
        $requiredTools = @("list_windows", "get_window", "activate_window", "get_window_state", "click", "type_text", "press_key", "set_value")
        $missingTools = @($requiredTools | Where-Object { $_ -notin $toolNames })
        if ($missingTools.Count -gt 0) {
            throw "Packaged MCP runtime is missing required tools: $($missingTools -join ', ')"
        }
    } finally {
        if (Test-Path -LiteralPath $verificationRoot) {
            for ($attempt = 1; $attempt -le 10; $attempt++) {
                try {
                    Remove-Item -LiteralPath $verificationRoot -Recurse -Force -ErrorAction Stop
                    break
                } catch {
                    if ($attempt -eq 10) { throw }
                    Start-Sleep -Milliseconds 100
                }
            }
        }
    }

    [ordered]@{
        status = "passed"
        package = $archive.FullName
        size = $archive.Length
        sha256 = Get-Sha256 $archive.FullName
        runtimeTargets = @("win32-x64", "win32-arm64")
        runtimeVersion = $runtimeVersion.Trim()
        mcpToolCount = $toolNames.Count
    } | ConvertTo-Json -Depth 4
} finally {
    Pop-Location
}

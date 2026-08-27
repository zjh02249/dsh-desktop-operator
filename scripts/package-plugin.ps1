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
    $mcpProcess = $null
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

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $packagedRuntime
        $startInfo.Arguments = "mcp"
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $mcpProcess = New-Object System.Diagnostics.Process
        $mcpProcess.StartInfo = $startInfo
        if (-not $mcpProcess.Start()) { throw "Could not start the packaged MCP runtime." }
        $stderrTask = $mcpProcess.StandardError.ReadToEndAsync()

        function Invoke-PackagedMcpRequest([string]$request, [int]$expectedId) {
            $mcpProcess.StandardInput.WriteLine($request)
            $mcpProcess.StandardInput.Flush()
            for ($attempt = 1; $attempt -le 20; $attempt++) {
                $readTask = $mcpProcess.StandardOutput.ReadLineAsync()
                if (-not $readTask.Wait(30000)) {
                    throw "Packaged MCP runtime timed out waiting for JSON-RPC response id $expectedId."
                }
                if ($null -eq $readTask.Result) {
                    $stderr = if ($stderrTask.IsCompleted) { $stderrTask.Result.Trim() } else { "" }
                    throw "Packaged MCP runtime closed stdout before JSON-RPC response id $expectedId. stderr: $stderr"
                }
                $response = $readTask.Result | ConvertFrom-Json
                if ($response.id -ne $expectedId) { continue }
                if ($null -ne $response.error) {
                    throw "Packaged MCP runtime returned an error for JSON-RPC id $expectedId`: $($response.error | ConvertTo-Json -Compress)"
                }
                return $response
            }
            throw "Packaged MCP runtime did not return JSON-RPC response id $expectedId."
        }

        $initializeRequest = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"package-verifier","version":"1"}}}'
        $initializedNotification = '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
        $toolsRequest = '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
        $initializeResponse = Invoke-PackagedMcpRequest $initializeRequest 1
        if ($initializeResponse.result.protocolVersion -ne "2025-03-26") {
            throw "Packaged MCP runtime returned unexpected protocol version '$($initializeResponse.result.protocolVersion)'."
        }
        $mcpProcess.StandardInput.WriteLine($initializedNotification)
        $mcpProcess.StandardInput.Flush()
        $toolsResponse = Invoke-PackagedMcpRequest $toolsRequest 2
        $toolNames = @($toolsResponse.result.tools | ForEach-Object { $_.name })
        $requiredTools = @("list_windows", "get_window", "activate_window", "get_window_state", "click", "type_text", "press_key", "set_value")
        $missingTools = @($requiredTools | Where-Object { $_ -notin $toolNames })
        if ($missingTools.Count -gt 0) {
            throw "Packaged MCP runtime is missing required tools: $($missingTools -join ', ')"
        }
    } finally {
        if ($null -ne $mcpProcess) {
            if (-not $mcpProcess.HasExited) {
                try { $mcpProcess.StandardInput.Close() } catch {}
                if (-not $mcpProcess.WaitForExit(3000)) {
                    $mcpProcess.Kill()
                    if (-not $mcpProcess.WaitForExit(5000)) {
                        throw "Packaged MCP verifier did not exit after termination."
                    }
                }
            }
            $mcpProcess.Dispose()
        }
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

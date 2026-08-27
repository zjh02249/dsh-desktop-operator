[CmdletBinding()]
param(
    [ValidateSet("amd64", "arm64")]
    [string[]]$Architecture = @("amd64", "arm64"),

    [string]$GoExecutable = "",

    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"
$pluginRoot = Split-Path -Parent $PSScriptRoot
$moduleRoot = Join-Path $pluginRoot "runtime\windows"
$binRoot = Join-Path $pluginRoot "runtime\bin"
$captureHelperSource = Join-Path $moduleRoot "capture_helper.cs"
$captureHelperOutput = Join-Path $moduleRoot "capture_helper.dll"

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

function Find-ContractReference([string]$SdkDirectory, [string]$ContractName) {
    $contractRoot = Join-Path $SdkDirectory $ContractName
    if (-not (Test-Path -LiteralPath $contractRoot -PathType Container)) {
        throw "Windows SDK contract not found: $contractRoot"
    }
    $reference = Get-ChildItem -LiteralPath $contractRoot -Filter "$ContractName.winmd" -File -Recurse |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if ($null -eq $reference) {
        throw "Windows SDK contract metadata not found below $contractRoot"
    }
    return $reference.FullName
}

function Build-CaptureHelper {
    if (-not (Test-Path -LiteralPath $captureHelperSource -PathType Leaf)) {
        throw "Windows capture helper source not found: $captureHelperSource"
    }

    $frameworkRoot = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319"
    if (-not (Test-Path -LiteralPath (Join-Path $frameworkRoot "csc.exe") -PathType Leaf)) {
        $frameworkRoot = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319"
    }
    $compiler = Join-Path $frameworkRoot "csc.exe"
    $windowsRuntimeReference = Join-Path $frameworkRoot "System.Runtime.WindowsRuntime.dll"

    $referenceAssemblyRoot = Join-Path ${env:ProgramFiles(x86)} "Reference Assemblies\Microsoft\Framework\.NETFramework"
    $facadeRoot = Get-ChildItem -LiteralPath $referenceAssemblyRoot -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "Facades\System.Runtime.dll") -PathType Leaf } |
        Sort-Object { [version]($_.Name.TrimStart("v")) } -Descending |
        Select-Object -First 1 |
        ForEach-Object { Join-Path $_.FullName "Facades" }

    $windowsKitsRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10"
    $sdkDirectory = Get-ChildItem -LiteralPath (Join-Path $windowsKitsRoot "References") -Directory |
        Sort-Object { [version]$_.Name } -Descending |
        Select-Object -First 1
    if ($null -eq $sdkDirectory) {
        throw "No Windows 10 SDK contract references were found below $windowsKitsRoot"
    }

    $references = @(
        $windowsRuntimeReference,
        (Join-Path $facadeRoot "System.Runtime.dll"),
        (Join-Path $facadeRoot "System.Runtime.InteropServices.WindowsRuntime.dll"),
        (Join-Path $windowsKitsRoot "UnionMetadata\Facade\Windows.WinMD"),
        (Find-ContractReference $sdkDirectory.FullName "Windows.Foundation.FoundationContract"),
        (Find-ContractReference $sdkDirectory.FullName "Windows.Foundation.UniversalApiContract")
    )
    $missingReferences = @($references | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf) -or $null -eq $facadeRoot -or $missingReferences.Count -gt 0) {
        throw "The .NET Framework/Windows SDK compiler references required for Windows.Graphics.Capture are incomplete. Missing: $($missingReferences -join ', ')"
    }

    $compilerArguments = @("/nologo", "/target:library", "/optimize+", "/platform:anycpu", "/out:$captureHelperOutput")
    $compilerArguments += $references | ForEach-Object { "/reference:$_" }
    $compilerArguments += $captureHelperSource
    & $compiler @compilerArguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $captureHelperOutput -PathType Leaf)) {
        throw "Windows capture helper compilation failed with exit code $LASTEXITCODE."
    }

    return [ordered]@{
        source = "runtime/windows/capture_helper.cs"
        embeddedFile = "runtime/windows/capture_helper.dll"
        windowsSdk = $sdkDirectory.Name
        size = (Get-Item -LiteralPath $captureHelperOutput).Length
        sha256 = Get-Sha256 $captureHelperOutput
    }
}

if ([string]::IsNullOrWhiteSpace($GoExecutable)) {
    $goCommand = @(Get-Command go -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($null -eq $goCommand) {
        throw "Go was not found. Install Go 1.22 or newer, or pass -GoExecutable <absolute-path>."
    }
    $GoExecutable = $goCommand.Source
} else {
    $GoExecutable = [System.IO.Path]::GetFullPath($GoExecutable)
    if (-not (Test-Path -LiteralPath $GoExecutable -PathType Leaf)) {
        throw "Go executable not found: $GoExecutable"
    }
}

$package = Get-Content -Raw -LiteralPath (Join-Path $pluginRoot "package.json") | ConvertFrom-Json
$upstream = Get-Content -Raw -LiteralPath (Join-Path $pluginRoot "runtime\upstream.json") | ConvertFrom-Json
$version = [string]$package.version
$artifacts = @()
$captureHelper = Build-CaptureHelper

Push-Location $moduleRoot
try {
    if (-not $SkipTests) {
        & $GoExecutable test ./...
        if ($LASTEXITCODE -ne 0) { throw "Windows runtime tests failed with exit code $LASTEXITCODE." }
        & $GoExecutable vet ./...
        if ($LASTEXITCODE -ne 0) { throw "Windows runtime vet failed with exit code $LASTEXITCODE." }
    }

    $previousGoos = $env:GOOS
    $previousGoarch = $env:GOARCH
    $previousCgo = $env:CGO_ENABLED
    try {
        $env:GOOS = "windows"
        $env:CGO_ENABLED = "0"
        foreach ($arch in $Architecture) {
            $env:GOARCH = $arch
            $nodeArch = if ($arch -eq "amd64") { "x64" } else { "arm64" }
            $target = "win32-$nodeArch"
            $outputDirectory = Join-Path $binRoot $target
            $output = Join-Path $outputDirectory "open-computer-use.exe"
            New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

            $ldflags = "-s -w -X main.version=$version"
            & $GoExecutable @("build", "-trimpath", "-ldflags", $ldflags, "-o", $output, ".")
            if ($LASTEXITCODE -ne 0) { throw "Windows runtime build failed for $arch with exit code $LASTEXITCODE." }

            $item = Get-Item -LiteralPath $output
            $artifacts += [ordered]@{
                target = $target
                file = "runtime/bin/$target/open-computer-use.exe"
                size = $item.Length
                sha256 = Get-Sha256 $output
            }
        }
    } finally {
        if ($null -eq $previousGoos) { Remove-Item Env:GOOS -ErrorAction SilentlyContinue } else { $env:GOOS = $previousGoos }
        if ($null -eq $previousGoarch) { Remove-Item Env:GOARCH -ErrorAction SilentlyContinue } else { $env:GOARCH = $previousGoarch }
        if ($null -eq $previousCgo) { Remove-Item Env:CGO_ENABLED -ErrorAction SilentlyContinue } else { $env:CGO_ENABLED = $previousCgo }
    }
} finally {
    Pop-Location
}

$manifest = [ordered]@{
    schemaVersion = 1
    pluginVersion = $version
    source = [ordered]@{
        repository = [string]$upstream.repository
        baseCommit = [string]$upstream.baseCommit
        sourceState = [string]$upstream.sourceState
    }
    captureHelper = $captureHelper
    artifacts = $artifacts
}
$manifestPath = Join-Path $binRoot "runtime-manifest.json"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($manifestPath, (($manifest | ConvertTo-Json -Depth 6) + [Environment]::NewLine), $utf8NoBom)
$manifest | ConvertTo-Json -Depth 6

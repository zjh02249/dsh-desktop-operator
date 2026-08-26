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

if ([string]::IsNullOrWhiteSpace($GoExecutable)) {
    $goCommand = Get-Command go -CommandType Application -ErrorAction SilentlyContinue
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
    artifacts = $artifacts
}
$manifestPath = Join-Path $binRoot "runtime-manifest.json"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($manifestPath, (($manifest | ConvertTo-Json -Depth 6) + [Environment]::NewLine), $utf8NoBom)
$manifest | ConvertTo-Json -Depth 6

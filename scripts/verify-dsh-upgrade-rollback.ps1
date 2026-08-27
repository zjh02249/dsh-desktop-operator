[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PreviousPackagePath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CurrentPackagePath,

    [string]$DshCliPath = "node_modules\@deepseek-ai\dsh\lib\bin.js",

    [string]$OutputPath = "artifacts\security\upgrade-rollback-report.json",

    [switch]$KeepSandbox
)

$ErrorActionPreference = "Stop"
$pluginRoot = Split-Path -Parent $PSScriptRoot
function Resolve-InputFile([string]$Path, [string]$Description) {
    $resolved = if ([System.IO.Path]::IsPathRooted($Path)) {
        [System.IO.Path]::GetFullPath($Path)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $pluginRoot $Path))
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "$Description does not exist: $resolved" }
    return $resolved
}
$previousPackage = Resolve-InputFile $PreviousPackagePath "Previous package"
$currentPackage = Resolve-InputFile $CurrentPackagePath "Current package"
$resolvedDshCli = Resolve-InputFile $DshCliPath "DSH CLI"
$resolvedOutputPath = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
    [System.IO.Path]::GetFullPath($OutputPath)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $pluginRoot $OutputPath))
}
$node = @(Get-Command node -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
if ($null -eq $node) { throw "node was not found." }
$sandboxRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dsh-desktop-operator-upgrade-rollback-" + [guid]::NewGuid().ToString("N"))
$profileName = "upgrade-rollback"
$previousDshHome = $env:DSH_HOME
$transitions = @()

function Get-ArchivePackageVersion([string]$ArchivePath) {
    $tar = @(Get-Command tar -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($null -eq $tar) { throw "tar was not found." }
    $packageJson = [string](& $tar.Source -xOf $ArchivePath package/package.json)
    if ($LASTEXITCODE -ne 0) { throw "Could not read package.json from $ArchivePath." }
    return [string](($packageJson | ConvertFrom-Json).version)
}

function Invoke-DshPluginInstall([string]$ArchivePath, [string]$ExpectedVersion, [string]$Stage) {
    & $node.Source $resolvedDshCli plugin --profile $profileName add --save-exact --config.auto-install-peers=false $ArchivePath
    if ($LASTEXITCODE -ne 0) { throw "DSH plugin installation failed during $Stage with exit code $LASTEXITCODE." }
    $installedRoot = Join-Path $sandboxRoot "profiles\$profileName\node_modules\dsh-desktop-operator"
    $installedPackagePath = Join-Path $installedRoot "package.json"
    if (-not (Test-Path -LiteralPath $installedPackagePath -PathType Leaf)) {
        throw "DSH did not install dsh-desktop-operator during $Stage."
    }
    $installedVersion = [string]((Get-Content -Raw -LiteralPath $installedPackagePath | ConvertFrom-Json).version)
    if ($installedVersion -ne $ExpectedVersion) {
        throw "Installed package version mismatch during $Stage. Expected $ExpectedVersion, received $installedVersion."
    }
    $runtime = Join-Path $installedRoot "runtime\bin\win32-x64\open-computer-use.exe"
    $runtimeVersion = [string](& $runtime --version)
    if ($LASTEXITCODE -ne 0 -or $runtimeVersion.Trim() -ne $ExpectedVersion) {
        throw "Installed runtime version mismatch during $Stage. Expected $ExpectedVersion, received '$runtimeVersion'."
    }
    $profilePackage = Get-Content -Raw -LiteralPath (Join-Path $sandboxRoot "profiles\$profileName\package.json") | ConvertFrom-Json
    $installedSpec = [string]$profilePackage.dependencies.'dsh-desktop-operator'
    $bundleCount = @($profilePackage.dependencies.PSObject.Properties | Where-Object { $_.Name -eq "dsh-desktop-operator" }).Count
    if ($bundleCount -ne 1 -or [string]::IsNullOrWhiteSpace($installedSpec)) {
        throw "DSH profile must contain exactly one dsh-desktop-operator dependency during $Stage."
    }
    $script:transitions += [ordered]@{
        stage = $Stage
        packageVersion = $installedVersion
        runtimeVersion = $runtimeVersion.Trim()
        installedSpec = $installedSpec.Replace([char]'\', [char]'/')
        bundleCount = $bundleCount
    }
}

$previousVersion = Get-ArchivePackageVersion $previousPackage
$currentVersion = Get-ArchivePackageVersion $currentPackage
if ($previousVersion -eq $currentVersion) { throw "Previous and current package versions must differ." }

try {
    New-Item -ItemType Directory -Path $sandboxRoot -Force | Out-Null
    $env:DSH_HOME = $sandboxRoot
    # The required transition is deliberately explicit: previous -> current -> previous.
    Invoke-DshPluginInstall $previousPackage $previousVersion "previous-install"
    Invoke-DshPluginInstall $currentPackage $currentVersion "current-upgrade"
    Invoke-DshPluginInstall $previousPackage $previousVersion "previous-rollback"

    $report = [ordered]@{
        schemaVersion = 1
        status = "passed"
        generatedAtUtc = [DateTime]::UtcNow.ToString("o")
        dshCli = $resolvedDshCli.Replace([char]'\', [char]'/')
        dshHomeIsolated = $true
        previousVersion = $previousVersion
        currentVersion = $currentVersion
        transition = "previous -> current -> previous"
        transitions = $transitions
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $resolvedOutputPath) -Force | Out-Null
    [System.IO.File]::WriteAllText(
        $resolvedOutputPath,
        (($report | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
        [System.Text.UTF8Encoding]::new($false)
    )
    $report | ConvertTo-Json -Depth 8
} finally {
    if ($null -eq $previousDshHome) { Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue } else { $env:DSH_HOME = $previousDshHome }
    if (-not $KeepSandbox -and (Test-Path -LiteralPath $sandboxRoot)) {
        $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        $resolvedSandbox = [System.IO.Path]::GetFullPath($sandboxRoot)
        if (-not $resolvedSandbox.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove upgrade/rollback sandbox outside the OS temp root: $resolvedSandbox"
        }
        Remove-Item -LiteralPath $resolvedSandbox -Recurse -Force
    }
}

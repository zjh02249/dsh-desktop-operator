[CmdletBinding()]
param(
    [string]$OutputPath = "",

    [string]$RuntimeManifestPath = "runtime\bin\runtime-manifest.json"
)

$ErrorActionPreference = "Stop"
$pluginRoot = Split-Path -Parent $PSScriptRoot
$packagePath = Join-Path $pluginRoot "package.json"
$package = Get-Content -Raw -LiteralPath $packagePath | ConvertFrom-Json
$version = [string]$package.version
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = "artifacts\security\dsh-desktop-operator-$version.cdx.json"
}
$resolvedOutputPath = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
    [System.IO.Path]::GetFullPath($OutputPath)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $pluginRoot $OutputPath))
}
$resolvedManifestPath = if ([System.IO.Path]::IsPathRooted($RuntimeManifestPath)) {
    [System.IO.Path]::GetFullPath($RuntimeManifestPath)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $pluginRoot $RuntimeManifestPath))
}

function Get-NpmPurl([string]$Name, [string]$PackageVersion) {
    if ($Name.StartsWith("@") -and $Name.Contains("/")) {
        $parts = $Name.Substring(1).Split(@("/"), 2, [System.StringSplitOptions]::None)
        $encodedName = "%40$([Uri]::EscapeDataString($parts[0]))/$([Uri]::EscapeDataString($parts[1]))"
    } else {
        $encodedName = [Uri]::EscapeDataString($Name)
    }
    return "pkg:npm/$encodedName@$([Uri]::EscapeDataString($PackageVersion))"
}

function Get-GeneratedTimestamp {
    $epochText = [string]$env:SOURCE_DATE_EPOCH
    [long]$epoch = 0
    if (-not [string]::IsNullOrWhiteSpace($epochText) -and [long]::TryParse($epochText, [ref]$epoch)) {
        return [DateTimeOffset]::FromUnixTimeSeconds($epoch).UtcDateTime.ToString("o")
    }
    return [DateTime]::UtcNow.ToString("o")
}

function New-DeterministicSerialNumber([string]$Seed) {
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Seed))[0..15]
        $bytes[6] = ($bytes[6] -band 0x0f) -bor 0x50
        $bytes[8] = ($bytes[8] -band 0x3f) -bor 0x80
        return "urn:uuid:$([guid]::new([byte[]]$bytes))"
    } finally {
        $sha256.Dispose()
    }
}

$pnpm = @(Get-Command pnpm -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
if ($null -eq $pnpm) { throw "pnpm was not found." }
Push-Location $pluginRoot
try {
    # CycloneDX input is the complete production graph reported by: pnpm list --prod --json --depth Infinity
    $dependencyOutput = [string](& $pnpm.Source list --prod --json --depth Infinity)
    if ($LASTEXITCODE -ne 0) { throw "pnpm list --prod failed with exit code $LASTEXITCODE." }
} finally {
    Pop-Location
}
$dependencyRoots = @($dependencyOutput | ConvertFrom-Json)
if ($dependencyRoots.Count -ne 1) { throw "Expected one pnpm dependency root, found $($dependencyRoots.Count)." }

$componentsByRef = @{}
$dependenciesByRef = @{}
function Register-DependencyNode([string]$Name, [object]$Node) {
    $nodeVersion = [string]$Node.version
    if ([string]::IsNullOrWhiteSpace($nodeVersion)) { return "" }
    $reference = Get-NpmPurl $Name $nodeVersion
    if (-not $componentsByRef.ContainsKey($reference)) {
        $componentsByRef[$reference] = [ordered]@{
            type = "library"
            name = $Name
            version = $nodeVersion
            purl = $reference
            "bom-ref" = $reference
        }
    }
    if (-not $dependenciesByRef.ContainsKey($reference)) {
        $dependenciesByRef[$reference] = @{}
    }
    if ($null -ne $Node.dependencies) {
        foreach ($property in @($Node.dependencies.PSObject.Properties)) {
            $childReference = Register-DependencyNode ([string]$property.Name) $property.Value
            if (-not [string]::IsNullOrWhiteSpace($childReference)) {
                $dependenciesByRef[$reference][$childReference] = $true
            }
        }
    }
    return $reference
}

$rootReference = Get-NpmPurl ([string]$package.name) $version
$dependenciesByRef[$rootReference] = @{}
foreach ($property in @($dependencyRoots[0].dependencies.PSObject.Properties)) {
    $childReference = Register-DependencyNode ([string]$property.Name) $property.Value
    if (-not [string]::IsNullOrWhiteSpace($childReference)) {
        $dependenciesByRef[$rootReference][$childReference] = $true
    }
}

$runtimeComponents = @()
if (Test-Path -LiteralPath $resolvedManifestPath -PathType Leaf) {
    $runtimeManifest = Get-Content -Raw -LiteralPath $resolvedManifestPath | ConvertFrom-Json
    if ([string]$runtimeManifest.pluginVersion -ne $version) {
        throw "Runtime manifest version '$($runtimeManifest.pluginVersion)' does not match package version '$version'."
    }
    foreach ($artifact in @($runtimeManifest.artifacts)) {
        $artifactPath = [System.IO.Path]::GetFullPath((Join-Path $pluginRoot ([string]$artifact.file)))
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
            throw "Runtime artifact listed in the manifest is missing: $artifactPath"
        }
        $actualHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualHash -ne ([string]$artifact.sha256).ToUpperInvariant()) {
            throw "Runtime artifact hash does not match the manifest: $artifactPath"
        }
        $runtimeReference = "urn:dsh-desktop-operator:runtime:$([string]$artifact.target):$version"
        $runtimeComponents += [ordered]@{
            type = "file"
            name = "open-computer-use-$([string]$artifact.target).exe"
            version = $version
            "bom-ref" = $runtimeReference
            hashes = @([ordered]@{ alg = "SHA-256"; content = $actualHash })
            properties = @([ordered]@{ name = "dsh-desktop-operator:target"; value = [string]$artifact.target })
        }
        $dependenciesByRef[$rootReference][$runtimeReference] = $true
        $dependenciesByRef[$runtimeReference] = @{}
    }
}

$commit = [string](& git -C $pluginRoot rev-parse HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commit)) { $commit = "unknown" }
$rootComponent = [ordered]@{
    type = "application"
    name = [string]$package.name
    version = $version
    purl = $rootReference
    "bom-ref" = $rootReference
    licenses = @([ordered]@{ license = [ordered]@{ id = [string]$package.license } })
}
$allComponents = @($componentsByRef.Values | Sort-Object { [string]$_['bom-ref'] }) + @($runtimeComponents | Sort-Object { [string]$_['bom-ref'] })
$dependencyEntries = @($dependenciesByRef.Keys | Sort-Object | ForEach-Object {
    [ordered]@{
        ref = $_
        dependsOn = @($dependenciesByRef[$_].Keys | Sort-Object)
    }
})
$bom = [ordered]@{
    bomFormat = "CycloneDX"
    specVersion = "1.6"
    serialNumber = New-DeterministicSerialNumber "$($package.name)@$version@$commit"
    version = 1
    metadata = [ordered]@{
        timestamp = Get-GeneratedTimestamp
        tools = [ordered]@{
            components = @([ordered]@{ type = "application"; name = "generate-sbom.ps1"; version = $version })
        }
        component = $rootComponent
        properties = @([ordered]@{ name = "dsh-desktop-operator:git-commit"; value = $commit.Trim() })
    }
    components = $allComponents
    dependencies = $dependencyEntries
}

$outputDirectory = Split-Path -Parent $resolvedOutputPath
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $resolvedOutputPath,
    (($bom | ConvertTo-Json -Depth 100) + [Environment]::NewLine),
    [System.Text.UTF8Encoding]::new($false)
)
[ordered]@{
    status = "passed"
    format = "CycloneDX"
    specVersion = "1.6"
    path = $resolvedOutputPath
    sha256 = (Get-FileHash -LiteralPath $resolvedOutputPath -Algorithm SHA256).Hash.ToUpperInvariant()
    componentCount = $allComponents.Count + 1
} | ConvertTo-Json -Depth 4

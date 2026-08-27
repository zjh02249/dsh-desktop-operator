[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Files,

    [string]$ReportPath = "artifacts\security\windows-signing-report.json",

    [string]$RuntimeManifestPath = "",

    [string]$SignToolPath = "",

    [string]$CertificateThumbprint = $env:WINDOWS_SIGNING_CERT_THUMBPRINT,

    [string]$TimestampUrl = "http://timestamp.digicert.com",

    [switch]$RequireSigning
)

$ErrorActionPreference = "Stop"
$pluginRoot = Split-Path -Parent $PSScriptRoot
$resolvedFiles = @($Files | ForEach-Object {
    $candidate = if ([System.IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $pluginRoot $_ }
    $resolved = [System.IO.Path]::GetFullPath($candidate)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Signing input does not exist: $resolved"
    }
    $resolved
})
$resolvedReportPath = if ([System.IO.Path]::IsPathRooted($ReportPath)) {
    [System.IO.Path]::GetFullPath($ReportPath)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $pluginRoot $ReportPath))
}
$reportDirectory = Split-Path -Parent $resolvedReportPath
New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
$pfxBase64 = [string]$env:WINDOWS_SIGNING_PFX_BASE64
$pfxPassword = [string]$env:WINDOWS_SIGNING_PFX_PASSWORD
$temporaryRoot = $null
$importedCertificate = $null
$certificate = $null
$resolvedSignTool = ""
$startedAt = [DateTime]::UtcNow
$signatureEvidenceByPath = @{}

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

function Get-PortableRelativePath([string]$BasePath, [string]$TargetPath) {
    $resolvedBase = [System.IO.Path]::GetFullPath($BasePath).TrimEnd([char]'\', [char]'/') + [System.IO.Path]::DirectorySeparatorChar
    $resolvedTarget = [System.IO.Path]::GetFullPath($TargetPath)
    if ($resolvedTarget.StartsWith($resolvedBase, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $resolvedTarget.Substring($resolvedBase.Length).Replace([char]'\', [char]'/')
    }
    return $resolvedTarget.Replace([char]'\', [char]'/')
}

function Resolve-SignTool([string]$ExplicitPath) {
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $resolved = [System.IO.Path]::GetFullPath($ExplicitPath)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "SignTool was not found at the explicit path: $resolved"
        }
        return $resolved
    }
    $command = @(Get-Command signtool.exe -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($null -ne $command) { return $command.Source }
    $kitsRoot = "C:\Program Files (x86)\Windows Kits\10\bin"
    $candidate = Get-ChildItem -LiteralPath $kitsRoot -Filter signtool.exe -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\x64\\signtool\.exe$" } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if ($null -eq $candidate) {
        throw "signtool.exe was not found. Install the Windows SDK signing tools."
    }
    return $candidate.FullName
}

function Write-SigningReport([string]$Status, [string]$ErrorCode = "") {
    $fileEvidence = @($resolvedFiles | ForEach-Object {
        $signatureEvidence = if ($signatureEvidenceByPath.ContainsKey($_)) {
            $signatureEvidenceByPath[$_]
        } elseif ($Status -eq "unsigned") {
            [ordered]@{
                status = "NotSigned"
                signerThumbprint = ""
                verifier = "not-requested"
            }
        } else {
            [ordered]@{
                status = "Unknown"
                signerThumbprint = ""
                verifier = "not-completed"
            }
        }
        [ordered]@{
            path = Get-PortableRelativePath $pluginRoot $_
            size = (Get-Item -LiteralPath $_).Length
            sha256 = Get-Sha256 $_
            signatureStatus = [string]$signatureEvidence.status
            signerThumbprint = [string]$signatureEvidence.signerThumbprint
            verifier = [string]$signatureEvidence.verifier
        }
    })
    $report = [ordered]@{
        schemaVersion = 1
        status = $Status
        required = [bool]$RequireSigning
        generatedAtUtc = [DateTime]::UtcNow.ToString("o")
        durationMs = [long]([DateTime]::UtcNow - $startedAt).TotalMilliseconds
        timestampUrl = $TimestampUrl
        signTool = $resolvedSignTool
        certificate = if ($null -ne $certificate) {
            [ordered]@{
                subject = [string]$certificate.Subject
                thumbprint = [string]$certificate.Thumbprint
                notBeforeUtc = $certificate.NotBefore.ToUniversalTime().ToString("o")
                notAfterUtc = $certificate.NotAfter.ToUniversalTime().ToString("o")
            }
        } else { $null }
        errorCode = $ErrorCode
        files = $fileEvidence
    }
    [System.IO.File]::WriteAllText(
        $resolvedReportPath,
        ($report | ConvertTo-Json -Depth 8),
        [System.Text.UTF8Encoding]::new($false)
    )
    return [pscustomobject]$report
}

function Update-RuntimeManifest([string]$ManifestPath) {
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) { return }
    $resolvedManifest = if ([System.IO.Path]::IsPathRooted($ManifestPath)) {
        [System.IO.Path]::GetFullPath($ManifestPath)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $pluginRoot $ManifestPath))
    }
    if (-not (Test-Path -LiteralPath $resolvedManifest -PathType Leaf)) {
        throw "Runtime manifest does not exist: $resolvedManifest"
    }
    $manifest = Get-Content -Raw -LiteralPath $resolvedManifest | ConvertFrom-Json
    foreach ($artifact in @($manifest.artifacts)) {
        $artifactPath = [System.IO.Path]::GetFullPath((Join-Path $pluginRoot ([string]$artifact.file)))
        if ($artifactPath -in $resolvedFiles) {
            $artifact.size = (Get-Item -LiteralPath $artifactPath).Length
            $artifact.sha256 = Get-Sha256 $artifactPath
        }
    }
    [System.IO.File]::WriteAllText(
        $resolvedManifest,
        ($manifest | ConvertTo-Json -Depth 12),
        [System.Text.UTF8Encoding]::new($false)
    )
}

try {
    $requested = -not [string]::IsNullOrWhiteSpace($CertificateThumbprint) -or -not [string]::IsNullOrWhiteSpace($pfxBase64)
    if (-not $requested) {
        $report = Write-SigningReport "unsigned" "signing_material_unavailable"
        if ($RequireSigning) {
            throw "Windows signing is required, but neither WINDOWS_SIGNING_CERT_THUMBPRINT nor WINDOWS_SIGNING_PFX_BASE64 is configured."
        }
        $report | ConvertTo-Json -Depth 8
    } else {
        $resolvedSignTool = Resolve-SignTool $SignToolPath
        if (-not [string]::IsNullOrWhiteSpace($pfxBase64)) {
            $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dsh-desktop-operator-signing-" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
            $pfxPath = Join-Path $temporaryRoot "certificate.pfx"
            try {
                [System.IO.File]::WriteAllBytes($pfxPath, [Convert]::FromBase64String($pfxBase64))
            } catch {
                throw "WINDOWS_SIGNING_PFX_BASE64 is not valid base64."
            }
            $securePassword = ConvertTo-SecureString $pfxPassword -AsPlainText -Force
            $importedCertificate = Import-PfxCertificate -FilePath $pfxPath -CertStoreLocation "Cert:\CurrentUser\My" -Password $securePassword -Exportable:$false
            if ($null -eq $importedCertificate) { throw "The PFX did not import a certificate." }
            $CertificateThumbprint = [string]$importedCertificate.Thumbprint
        }

        $normalizedThumbprint = ($CertificateThumbprint -replace "\s", "").ToUpperInvariant()
        $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$normalizedThumbprint" -ErrorAction Stop
        if (-not $certificate.HasPrivateKey) { throw "The signing certificate has no private key." }
        $codeSigningEku = @($certificate.EnhancedKeyUsageList | Where-Object { $_.ObjectId.Value -eq "1.3.6.1.5.5.7.3.3" })
        if ($codeSigningEku.Count -eq 0) { throw "The selected certificate is not valid for code signing." }
        if ($certificate.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or $certificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow) {
            throw "The selected code-signing certificate is not currently valid."
        }

        foreach ($path in $resolvedFiles) {
            & $resolvedSignTool sign /sha1 $normalizedThumbprint /s My /fd SHA256 /tr $TimestampUrl /td SHA256 $path
            if ($LASTEXITCODE -ne 0) { throw "SignTool failed to sign $path with exit code $LASTEXITCODE." }
            & $resolvedSignTool verify /pa /all /v $path
            if ($LASTEXITCODE -ne 0) { throw "SignTool verification failed for $path with exit code $LASTEXITCODE." }
            $signature = $null
            try {
                $signature = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
            } catch {
                $signatureEvidenceByPath[$path] = [ordered]@{
                    status = "VerifiedBySignTool"
                    signerThumbprint = $normalizedThumbprint
                    verifier = "signtool-/pa"
                }
            }
            if ($null -ne $signature) {
                if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
                    throw "Authenticode verification did not return Valid for $path; status=$($signature.Status)."
                }
                if ([string]$signature.SignerCertificate.Thumbprint -ne $normalizedThumbprint) {
                    throw "Authenticode signer mismatch for $path."
                }
                $signatureEvidenceByPath[$path] = [ordered]@{
                    status = [string]$signature.Status
                    signerThumbprint = [string]$signature.SignerCertificate.Thumbprint
                    verifier = "signtool-/pa+Get-AuthenticodeSignature"
                }
            }
        }

        Update-RuntimeManifest $RuntimeManifestPath
        $report = Write-SigningReport "signed"
        $report | ConvertTo-Json -Depth 8
    }
} catch {
    try { [void](Write-SigningReport "failed" "signing_failed") } catch {}
    throw
} finally {
    if ($null -ne $importedCertificate) {
        Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($importedCertificate.Thumbprint)" -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $temporaryRoot -and (Test-Path -LiteralPath $temporaryRoot)) {
        $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        $resolvedTemporaryRoot = [System.IO.Path]::GetFullPath($temporaryRoot)
        if (-not $resolvedTemporaryRoot.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove signing temporary directory outside the OS temp root: $resolvedTemporaryRoot"
        }
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
    }
}

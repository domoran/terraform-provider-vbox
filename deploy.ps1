<#
.SYNOPSIS
    Deploys the vbox provider to a local OpenTofu file-based registry.

.DESCRIPTION
    Cross-compiles the provider for the requested platforms and installs one
    zip per platform into the OpenTofu "packed" filesystem mirror layout under
    the given registry directory:

        <RegistryDirectory>\registry.terraform.io\eran132\vbox\
            terraform-provider-vbox_<version>_<os>_<arch>.zip

    Each zip contains the provider binary at its root, named
    terraform-provider-vbox_<version>_<os>_<arch>[.exe].

    Hostname/namespace/type match the serve address in main.go
    (tf5server.Serve "registry.terraform.io/eran132/vbox").

    The provider version is injected at build time via
    -ldflags "-X main.version=<version>" (main.go defaults to "dev").

    The registry is consumed via a CLI config file (provider_installation /
    filesystem_mirror), e.g. C:\Coding\tofu_registry\tofu.tfrc.

.PARAMETER RegistryDirectory
    Root directory of the local filesystem registry (created if missing).
    Example: C:\Coding\tofu_registry.
    Defaults to C:\Coding\tofu_registry.

.PARAMETER Version
    Provider version to deploy. Defaults to the first semantic version found
    in the top-level CHANGELOG.md entries.

.PARAMETER Targets
    List of GOOS/GOARCH pairs to build.
    Defaults to windows/amd64, linux/amd64, darwin/amd64, darwin/arm64.

.EXAMPLE
    .\deploy.ps1

.EXAMPLE
    .\deploy.ps1 D:\shared\tofu_registry

.EXAMPLE
    .\deploy.ps1 D:\shared\tofu_registry -Version 1.2.0 -Targets "windows/amd64","linux/amd64"
#>
[CmdletBinding()]
param(
    [string]$RegistryDirectory = "C:\Coding\tofu_registry",
    [string]$Version = "",
    [string[]]$Targets = @("windows/amd64", "linux/amd64", "darwin/amd64", "darwin/arm64")
)

$ErrorActionPreference = "Stop"

$ProviderType = "vbox"
$Namespace    = "eran132"
$Hostname     = "registry.terraform.io"

$repoRoot = $PSScriptRoot
Set-Location $repoRoot

# Pick up the version from CHANGELOG.md when not given explicitly.
if (-not $Version) {
    $match = Select-String -Path "CHANGELOG.md" -Pattern '^## v(\d+\.\d+\.\d+)' | Select-Object -First 1
    if ($match) {
        $Version = $match.Matches[0].Groups[1].Value
    } else {
        throw "Could not determine provider version from CHANGELOG.md. Pass -Version explicitly."
    }
}

Write-Host "Deploying ${Namespace}/${ProviderType} v${Version} to ${RegistryDirectory}" -ForegroundColor Cyan

try {
    foreach ($target in $Targets) {
        $parts  = $target -split "/"
        $goos   = $parts[0]
        $goarch = $parts[1]
        if ($parts.Count -ne 2) {
            throw "Invalid target '$target' (expected GOOS/GOARCH, e.g. windows/amd64)."
        }

        $binaryName  = "terraform-provider-${ProviderType}_${Version}_${goos}_${goarch}"
        if ($goos -eq "windows") { $binaryName += ".exe" }
        $zipName     = "terraform-provider-${ProviderType}_${Version}_${goos}_${goarch}.zip"

        $stagingDir = Join-Path $repoRoot "build/staging/${goos}_${goarch}"
        New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null

        Write-Host "  building ${goos}/${goarch} ..."
        $env:GOOS   = $goos
        $env:GOARCH = $goarch
        $binaryPath = Join-Path $stagingDir $binaryName
        go build -trimpath -ldflags "-s -w -X main.version=${Version}" -o $binaryPath .
        if ($LASTEXITCODE -ne 0) {
            throw "go build failed for ${goos}/${goarch} (exit code ${LASTEXITCODE})."
        }

        $destDir = Join-Path $RegistryDirectory "$Hostname/$Namespace/$ProviderType"
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
        $zipPath = Join-Path $destDir $zipName

        # Zip the binary so it sits at the root of the archive.
        Remove-Item $zipPath -ErrorAction SilentlyContinue
        Compress-Archive -Path $binaryPath -DestinationPath $zipPath
        Write-Host "  deployed $zipPath"
    }
} finally {
    Remove-Item Env:GOOS -ErrorAction SilentlyContinue
    Remove-Item Env:GOARCH -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Done. Registry layout:" -ForegroundColor Green
Get-ChildItem (Join-Path $RegistryDirectory "$Hostname/$Namespace/$ProviderType") | ForEach-Object {
    Write-Host "  $($_.FullName)  ($([math]::Round($_.Length / 1MB, 1)) MB)"
}

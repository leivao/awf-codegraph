[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA "AWF/CodeGraph"),
    [switch]$SkipOptionalTools,
    [switch]$SkipPathUpdate
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$installScript = Join-Path $scriptRoot "install.ps1"

if (!(Test-Path -LiteralPath $installScript)) {
    throw "Install script not found: $installScript"
}

& $installScript -InstallRoot $InstallRoot -SkipOptionalTools:$SkipOptionalTools -SkipPathUpdate:$SkipPathUpdate

Write-Host "Upgraded AWF Code Graph Toolkit at $InstallRoot" -ForegroundColor Green

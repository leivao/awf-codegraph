[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA "AWF/CodeGraph"),
    [switch]$SkipPathUpdate
)

$ErrorActionPreference = "Stop"

$binRoot = Join-Path $InstallRoot "bin"

if (Test-Path -LiteralPath $InstallRoot) {
    Remove-Item -LiteralPath $InstallRoot -Recurse -Force
    Write-Host "Removed AWF Code Graph Toolkit from $InstallRoot" -ForegroundColor Green
}
else {
    Write-Host "AWF Code Graph Toolkit was not installed at $InstallRoot" -ForegroundColor Yellow
}

if ($SkipPathUpdate) {
    Write-Host "Skipped PATH update because -SkipPathUpdate was specified." -ForegroundColor Yellow
    return
}

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$pathParts = @($userPath -split ";" | Where-Object { $_ })
$remainingParts = @($pathParts | Where-Object { $_.TrimEnd("\") -ine $binRoot.TrimEnd("\") })

if ($remainingParts.Count -ne $pathParts.Count) {
    [Environment]::SetEnvironmentVariable("Path", ($remainingParts -join ";"), "User")
    Write-Host "Removed $binRoot from the current user's PATH. Open a new shell for the change to apply." -ForegroundColor Yellow
}
else {
    Write-Host "$binRoot was not present in the current user's PATH." -ForegroundColor Cyan
}

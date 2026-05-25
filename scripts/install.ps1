[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA "AWF/CodeGraph"),
    [switch]$SkipOptionalTools,
    [switch]$SkipPathUpdate
)

$ErrorActionPreference = "Stop"

$sourceRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$toolRoot = Join-Path $InstallRoot "toolkit"
$binRoot = Join-Path $InstallRoot "bin"

New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null
New-Item -ItemType Directory -Force -Path $binRoot | Out-Null

Copy-Item -LiteralPath (Join-Path $sourceRoot "awf.ps1") -Destination $toolRoot -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "src") -Destination $toolRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "scripts") -Destination $toolRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "templates") -Destination $toolRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "docs") -Destination $toolRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "config") -Destination $toolRoot -Recurse -Force

$launcherPath = Join-Path $binRoot "awf-graph.ps1"
$escapedToolRoot = $toolRoot.Replace("'", "''")
$launcher = @"
param(
    [Parameter(ValueFromRemainingArguments=`$true)]
    [string[]]`$RemainingArgs
)

`$tool = Join-Path '$escapedToolRoot' 'awf.ps1'
& powershell -NoProfile -ExecutionPolicy Bypass -File `$tool @RemainingArgs
exit `$LASTEXITCODE
"@
Set-Content -LiteralPath $launcherPath -Value $launcher -Encoding UTF8

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$pathParts = @($userPath -split ";" | Where-Object { $_ })
$pathAlreadyContainsBin = $false
foreach ($pathPart in $pathParts) {
    if ($pathPart.TrimEnd("\") -ieq $binRoot.TrimEnd("\")) {
        $pathAlreadyContainsBin = $true
        break
    }
}

if ($SkipPathUpdate) {
    Write-Host "Skipped PATH update because -SkipPathUpdate was specified." -ForegroundColor Yellow
}
elseif (!$pathAlreadyContainsBin) {
    [Environment]::SetEnvironmentVariable("Path", (($pathParts + $binRoot) -join ";"), "User")
    Write-Host "Added $binRoot to the current user's PATH. Open a new shell before running awf-graph globally." -ForegroundColor Yellow
}

function Install-AwfOptionalTool {
    param(
        [Parameter(Mandatory)][string]$CommandName,
        [Parameter(Mandatory)][string]$WingetId,
        [Parameter(Mandatory)][string]$Reason
    )

    if ($SkipOptionalTools) {
        Write-Host "Skipped optional tool '$CommandName' because -SkipOptionalTools was specified." -ForegroundColor Yellow
        return
    }

    if (Get-Command $CommandName -ErrorAction SilentlyContinue) {
        Write-Host "Optional tool '$CommandName' is already installed." -ForegroundColor Green
        return
    }

    if (!(Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "Optional tool '$CommandName' is missing. $Reason Install skipped because winget is unavailable." -ForegroundColor Yellow
        return
    }

    Write-Host "Optional tool '$CommandName' is missing. $Reason" -ForegroundColor Cyan
    Write-Host "This will run: winget install --id $WingetId --source winget" -ForegroundColor Cyan
    $answer = Read-Host "Install '$CommandName' with winget now? [y/N]"
    if ($answer -match "^(y|yes)$") {
        winget install --id $WingetId --source winget
    }
    else {
        Write-Host "Skipped '$CommandName'. AWF will continue with fallback behavior where available." -ForegroundColor Yellow
    }
}

Install-AwfOptionalTool -CommandName "rg" -WingetId "BurntSushi.ripgrep.MSVC" -Reason "It improves large-repository file discovery performance."
Install-AwfOptionalTool -CommandName "gh" -WingetId "GitHub.cli" -Reason "It can support future GitHub-oriented workflow automation."

Write-Host "Installed AWF Code Graph Toolkit into $toolRoot" -ForegroundColor Green
Write-Host "Launcher created at $launcherPath" -ForegroundColor Green
Write-Host "Run from any project in a new shell:" -ForegroundColor Cyan
Write-Host "  awf-graph init"
Write-Host "  awf-graph update"
Write-Host "  awf-graph context -Query `"keyword`""

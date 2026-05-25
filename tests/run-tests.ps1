[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = New-Object System.Collections.Generic.List[string]

function Add-TestFailure {
    param([Parameter(Mandatory)][string]$Message)
    $failures.Add($Message) | Out-Null
}

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (!$Condition) {
        Add-TestFailure $Message
    }
}

function Assert-PathExists {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )

    Assert-True -Condition (Test-Path -LiteralPath $Path) -Message $Message
}

function Assert-PathMissing {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )

    Assert-True -Condition (!(Test-Path -LiteralPath $Path)) -Message $Message
}

function Invoke-Test {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    Write-Host "[TEST] $Name" -ForegroundColor Cyan
    try {
        & $ScriptBlock
    }
    catch {
        Add-TestFailure "$Name threw: $($_.Exception.Message)"
    }
}

Invoke-Test "CLI modules import without unapproved verb warnings" {
    $moduleWarnings = @()
    Import-Module (Join-Path $repoRoot "src/Awf.Util.psm1") -Force -WarningVariable moduleWarnings -WarningAction Continue
    Import-Module (Join-Path $repoRoot "src/Awf.Git.psm1") -Force -WarningVariable +moduleWarnings -WarningAction Continue
    Import-Module (Join-Path $repoRoot "src/Awf.CodeGraph.psm1") -Force -WarningVariable +moduleWarnings -WarningAction Continue
    Import-Module (Join-Path $repoRoot "src/Awf.ContextPacket.psm1") -Force -WarningVariable +moduleWarnings -WarningAction Continue

    $unapprovedWarnings = @($moduleWarnings | Where-Object { [string]$_ -match "unapproved verbs" })
    Assert-True -Condition ($unapprovedWarnings.Count -eq 0) -Message "Expected no unapproved verb warnings, got $($unapprovedWarnings.Count)."
}

Invoke-Test "Windows command wrappers bypass execution policy for setup scripts" {
    foreach ($name in @("install", "upgrade", "uninstall")) {
        $wrapperPath = Join-Path $repoRoot "scripts/$name.cmd"
        Assert-PathExists -Path $wrapperPath -Message "Expected scripts/$name.cmd to exist."

        if (Test-Path -LiteralPath $wrapperPath) {
            $content = Get-Content -LiteralPath $wrapperPath -Raw -Encoding UTF8
            Assert-True -Condition ($content -match "-ExecutionPolicy Bypass") -Message "Expected scripts/$name.cmd to run PowerShell with ExecutionPolicy Bypass."
            Assert-True -Condition ($content -match "$name\.ps1") -Message "Expected scripts/$name.cmd to invoke $name.ps1."
            Assert-True -Condition ($content -match "%\*") -Message "Expected scripts/$name.cmd to forward caller arguments."
        }
    }
}

Invoke-Test "CLI init resolves imported module commands" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-cli-init-test-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Force -Path $repoPath | Out-Null
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") init -RepoPath $repoPath

        Assert-PathExists -Path (Join-Path $repoPath ".wi/graph/files.jsonl") -Message "CLI init should create graph files."
        Assert-PathExists -Path (Join-Path $repoPath ".wi/graph/symbols.jsonl") -Message "CLI init should create symbols file."
    }
    finally {
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}

Invoke-Test "Agents install creates repo-local instructions and preserves Copilot content" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-agents-test-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Force -Path (Join-Path $repoPath ".github") | Out-Null
        Set-Content -LiteralPath (Join-Path $repoPath ".github/copilot-instructions.md") -Value "# Project Copilot`n`nKeep this project note." -Encoding UTF8

        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") agents install -RepoPath $repoPath

        $codexSkill = Join-Path $repoPath ".codex/skills/awf-codegraph/SKILL.md"
        $copilotInstructions = Join-Path $repoPath ".github/copilot-instructions.md"
        $genericInstructions = Join-Path $repoPath ".wi/agent-instructions.md"

        Assert-PathExists -Path $codexSkill -Message "Agents install should create the Codex AWF skill."
        Assert-PathExists -Path $genericInstructions -Message "Agents install should create generic AWF instructions."

        $copilotContent = Get-Content -LiteralPath $copilotInstructions -Raw -Encoding UTF8
        Assert-True -Condition ($copilotContent -match "Keep this project note\.") -Message "Agents install should preserve existing Copilot content."
        Assert-True -Condition ($copilotContent -match "<!-- BEGIN AWF CODE GRAPH -->") -Message "Agents install should add AWF Copilot markers."
        Assert-True -Condition ($copilotContent -match "<!-- END AWF CODE GRAPH -->") -Message "Agents install should close AWF Copilot markers."

        $skillContent = Get-Content -LiteralPath $codexSkill -Raw -Encoding UTF8
        Assert-True -Condition ($skillContent -match "\.wi/runtime/context-packet\.md") -Message "Codex skill should point at the context packet."
        Assert-True -Condition ($skillContent -match "\.wi/graph") -Message "Codex skill should point at graph artifacts."
    }
    finally {
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}

Invoke-Test "Agents install creates best-effort post-commit hook when Git metadata exists" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-agents-hook-test-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Force -Path (Join-Path $repoPath ".git") | Out-Null

        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") agents install -RepoPath $repoPath

        $hookPath = Join-Path $repoPath ".git/hooks/post-commit"
        Assert-PathExists -Path $hookPath -Message "Agents install should create a post-commit hook when .git exists."

        if (Test-Path -LiteralPath $hookPath) {
            $hook = Get-Content -LiteralPath $hookPath -Raw -Encoding UTF8
            Assert-True -Condition ($hook -match "awf-graph update -ChangedOnly") -Message "Post-commit hook should refresh changed graph files."
            Assert-True -Condition ($hook -match "awf-graph impact") -Message "Post-commit hook should refresh impact report."
            Assert-True -Condition ($hook -match "exit 0") -Message "Post-commit hook should be non-blocking."
        }
    }
    finally {
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}

Invoke-Test "ChangedOnly indexes files from the last commit when working tree is clean" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-clean-commit-test-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Force -Path $repoPath | Out-Null
        $old = Get-Location
        try {
            Set-Location $repoPath
            git init | Out-Null
            git config user.email "awf-test@example.test" | Out-Null
            git config user.name "AWF Test" | Out-Null
            git config commit.gpgsign false | Out-Null

            Set-Content -LiteralPath (Join-Path $repoPath "VendorModule.cs") -Value "public class VendorModule { public void Before() {} }" -Encoding UTF8
            git add VendorModule.cs | Out-Null
            git commit -m "Initial vendor module" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Initial test commit failed." }

            Set-Content -LiteralPath (Join-Path $repoPath "VendorModule.cs") -Value "public class VendorModule { public void After() {} }" -Encoding UTF8
            git add VendorModule.cs | Out-Null
            git commit -m "Edit vendor endpoint" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Second test commit failed." }
        }
        finally {
            Set-Location $old
        }

        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -ChangedOnly -RepoPath $repoPath

        $changedPath = Join-Path $repoPath ".wi/graph/changed-files.txt"
        Assert-PathExists -Path $changedPath -Message "ChangedOnly should write changed-files.txt."

        if (Test-Path -LiteralPath $changedPath) {
            $changed = @(Get-Content -LiteralPath $changedPath -Encoding UTF8)
            Assert-True -Condition ($changed -contains "VendorModule.cs") -Message "ChangedOnly should include the file changed by the last clean commit."
        }

        $filesJsonl = Join-Path $repoPath ".wi/graph/files.jsonl"
        $filesText = if (Test-Path -LiteralPath $filesJsonl) { Get-Content -LiteralPath $filesJsonl -Raw -Encoding UTF8 } else { "" }
        Assert-True -Condition ([bool]($filesText -match "VendorModule\.cs")) -Message "ChangedOnly should index the file changed by the last clean commit."
    }
    finally {
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}

Invoke-Test "Upgrade installs toolkit and launcher into a temporary root" {
    $installRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-upgrade-test-" + [guid]::NewGuid().ToString("N"))
    try {
        & (Join-Path $repoRoot "scripts/upgrade.ps1") -InstallRoot $installRoot -SkipOptionalTools -SkipPathUpdate

        Assert-PathExists -Path (Join-Path $installRoot "toolkit/awf.ps1") -Message "Upgrade should install awf.ps1."
        Assert-PathExists -Path (Join-Path $installRoot "toolkit/src/Awf.Util.psm1") -Message "Upgrade should install source modules."
        Assert-PathExists -Path (Join-Path $installRoot "bin/awf-graph.ps1") -Message "Upgrade should install launcher."
    }
    finally {
        if (Test-Path -LiteralPath $installRoot) {
            Remove-Item -LiteralPath $installRoot -Recurse -Force
        }
    }
}

Invoke-Test "Uninstall removes toolkit and optional PATH entry" {
    $installRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-uninstall-test-" + [guid]::NewGuid().ToString("N"))
    $binRoot = Join-Path $installRoot "bin"
    $toolRoot = Join-Path $installRoot "toolkit"
    $previousUserPath = [Environment]::GetEnvironmentVariable("Path", "User")

    try {
        New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
        New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $binRoot "awf-graph.ps1") -Value "# test launcher" -Encoding UTF8

        $pathParts = @($previousUserPath -split ";" | Where-Object { $_ })
        [Environment]::SetEnvironmentVariable("Path", (($pathParts + $binRoot) -join ";"), "User")

        & (Join-Path $repoRoot "scripts/uninstall.ps1") -InstallRoot $installRoot

        Assert-PathMissing -Path $installRoot -Message "Uninstall should remove the install root."

        $currentUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
        $currentParts = @($currentUserPath -split ";" | Where-Object { $_ })
        $containsBin = @($currentParts | Where-Object { $_.TrimEnd("\") -ieq $binRoot.TrimEnd("\") }).Count -gt 0
        Assert-True -Condition (!$containsBin) -Message "Uninstall should remove the AWF bin directory from user PATH."
    }
    finally {
        [Environment]::SetEnvironmentVariable("Path", $previousUserPath, "User")
        if (Test-Path -LiteralPath $installRoot) {
            Remove-Item -LiteralPath $installRoot -Recurse -Force
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "FAILED" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host ""
Write-Host "PASSED" -ForegroundColor Green

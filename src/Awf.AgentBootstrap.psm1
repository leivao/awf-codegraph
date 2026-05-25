Import-Module (Join-Path $PSScriptRoot "Awf.Util.psm1") -Force

function Get-AwfTemplateRoot {
    $toolRoot = Split-Path -Parent $PSScriptRoot
    return (Join-Path $toolRoot "templates")
}

function Get-AwfTemplateContent {
    param([Parameter(Mandatory)][string]$RelativePath)

    $templatePath = Join-Path (Get-AwfTemplateRoot) $RelativePath
    if (!(Test-Path -LiteralPath $templatePath)) {
        throw "Template not found: $templatePath"
    }

    return Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
}

function Set-AwfTextFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    New-AwfDirectory (Split-Path -Parent $Path)
    Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
    Write-AwfInfo "Wrote $Path"
}

function Set-AwfMarkedSection {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Section
    )

    $begin = "<!-- BEGIN AWF CODE GRAPH -->"
    $end = "<!-- END AWF CODE GRAPH -->"
    $managedSection = "$begin`n$Section`n$end"

    New-AwfDirectory (Split-Path -Parent $Path)
    if (!(Test-Path -LiteralPath $Path)) {
        Set-Content -LiteralPath $Path -Value $managedSection -Encoding UTF8
        Write-AwfInfo "Wrote $Path"
        return
    }

    $existing = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $pattern = "(?s)<!-- BEGIN AWF CODE GRAPH -->.*?<!-- END AWF CODE GRAPH -->"
    if ($existing -match $pattern) {
        $updated = [regex]::Replace($existing, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $managedSection }, 1)
    }
    elseif ([string]::IsNullOrWhiteSpace($existing)) {
        $updated = $managedSection
    }
    else {
        $updated = $existing.TrimEnd() + "`n`n" + $managedSection
    }

    Set-Content -LiteralPath $Path -Value $updated -Encoding UTF8
    Write-AwfInfo "Updated $Path"
}

function Install-AwfPostCommitHook {
    param([Parameter(Mandatory)][string]$RepoPath)

    $gitPath = Join-Path $RepoPath ".git"
    if (!(Test-Path -LiteralPath $gitPath)) {
        Write-AwfWarn "Git hook skipped because no .git directory was found at $RepoPath."
        return
    }

    $hooksPath = Join-Path $gitPath "hooks"
    $hookPath = Join-Path $hooksPath "post-commit"
    $hook = Get-AwfTemplateContent -RelativePath "git-hooks/post-commit"
    Set-AwfTextFile -Path $hookPath -Content $hook
}

function Install-AwfAgentBootstrap {
    param([Parameter(Mandatory)][string]$RepoPath)

    $codexSkill = Get-AwfTemplateContent -RelativePath "codex-awf-codegraph-skill.md"
    $copilotSection = Get-AwfTemplateContent -RelativePath "copilot-instructions.md"
    $genericInstructions = Get-AwfTemplateContent -RelativePath "agent-instructions.md"

    Set-AwfTextFile -Path (Join-Path $RepoPath ".codex/skills/awf-codegraph/SKILL.md") -Content $codexSkill
    Set-AwfMarkedSection -Path (Join-Path $RepoPath ".github/copilot-instructions.md") -Section $copilotSection.Trim()
    Set-AwfTextFile -Path (Join-Path $RepoPath ".wi/agent-instructions.md") -Content $genericInstructions
    Install-AwfPostCommitHook -RepoPath $RepoPath

    Write-AwfSuccess "Agent bootstrap files installed."
}

Export-ModuleMember -Function @(
    "Install-AwfAgentBootstrap"
)

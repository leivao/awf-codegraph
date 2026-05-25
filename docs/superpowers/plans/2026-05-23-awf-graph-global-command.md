# AWF Graph Global Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install and run AWF Code Graph as a global `awf-graph` command that creates fast, bounded, project-local AI context packets.

**Architecture:** Keep the existing PowerShell toolkit and JSONL graph store. Add a command wrapper mode where `awf-graph update` maps to the existing graph operations, use config-driven scanning with optional `rg`, and emit both Markdown and JSON context packets from the same candidate set.

**Tech Stack:** PowerShell 5+/PowerShell 7 compatible scripts, JSON/JSONL files, optional `rg`, optional `winget`, optional `gh`.

---

## File Structure

- Modify `awf.ps1`: accept the shorter command shape used by the global launcher, while preserving `graph` area compatibility.
- Modify `src/Awf.Util.psm1`: add config loading and command discovery helpers.
- Modify `src/Awf.Git.psm1`: make file discovery config-driven and prefer `rg --files` when available.
- Modify `src/Awf.CodeGraph.psm1`: pass config into file discovery, record discovery metadata, and keep graph-state freshness useful for agents.
- Modify `src/Awf.ContextPacket.psm1`: build one context model and write both `.md` and `.json` packets.
- Modify `scripts/install.ps1`: install a user-level `awf-graph` launcher and ask before installing optional tools with `winget`.
- Modify `README.md`: document the global install and new command UX.
- Modify `templates/agent-instructions.md`: point agents at `awf-graph` commands.

## Task 1: CLI Shape For `awf-graph`

**Files:**
- Modify: `awf.ps1`

- [ ] **Step 1: Verify current command shape**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\awf.ps1 graph status -RepoPath .
```

Expected: The command prints `AWF Code Graph Toolkit` and a status list. It may show zero graph files if `.wi/graph` has not been initialized.

- [ ] **Step 2: Update `awf.ps1` parameters**

Replace the current `param(...)` block with this compatibility-aware block:

```powershell
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$AreaOrCommand = "status",

    [Parameter(Position=1)]
    [string]$Command,

    [string]$RepoPath = ".",

    [switch]$ChangedOnly,

    [string]$TaskFile,

    [string]$Query,

    [switch]$VerboseOutput
)
```

- [ ] **Step 3: Add command normalization**

In `awf.ps1`, after imports and before resolving the repo path, add:

```powershell
$validCommands = @("init", "update", "impact", "context", "query", "status")

if ($AreaOrCommand -eq "graph") {
    if ([string]::IsNullOrWhiteSpace($Command)) {
        $Command = "status"
    }
}
else {
    if (![string]::IsNullOrWhiteSpace($Command)) {
        throw "Unexpected argument '$Command'. Use: awf-graph $AreaOrCommand [options]."
    }

    $Command = $AreaOrCommand
}

if ($validCommands -notcontains $Command) {
    throw "Unknown command '$Command'. Valid commands: $($validCommands -join ', ')."
}
```

- [ ] **Step 4: Run old and new command shapes**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\awf.ps1 graph status -RepoPath .
powershell -NoProfile -ExecutionPolicy Bypass -File .\awf.ps1 status -RepoPath .
```

Expected: Both commands print status output.

- [ ] **Step 5: Record commit if git is available**

Run:

```powershell
git rev-parse --is-inside-work-tree
```

Expected in this workspace today: failure because this folder is not a git repository.

If the workspace is later initialized as git, run:

```powershell
git add awf.ps1
git commit -m "feat: support awf-graph command shape"
```

## Task 2: Shared Configuration And Tool Detection

**Files:**
- Modify: `src/Awf.Util.psm1`

- [ ] **Step 1: Add default config function**

Append this function to `src/Awf.Util.psm1`:

```powershell
function Get-AwfDefaultConfig {
    [pscustomobject]@{
        version = "0.1.0"
        graph = [pscustomobject]@{
            workspace = ".wi/graph"
            runtime = ".wi/runtime"
            logs = ".wi/logs"
            indexer = "powershell-regex-mvp"
            extensions = @(".cs", ".ts", ".tsx", ".js", ".jsx", ".py", ".json", ".csproj", ".sln", ".props", ".targets")
            excludeDirectories = @(".git", ".wi", "node_modules", "bin", "obj", "dist", "build")
        }
        contextPacket = [pscustomobject]@{
            maxSymbols = 80
            maxSummaries = 50
            maxRecommendedFiles = 25
        }
        upgradeHooks = [pscustomobject]@{
            dotnetRoslynIndexerCommand = $null
            treeSitterIndexerCommand = $null
            codeQlDatabaseCommand = $null
        }
    }
}
```

- [ ] **Step 2: Add config loader**

Append this function to `src/Awf.Util.psm1`:

```powershell
function Get-AwfConfig {
    param([string]$RootPath)

    $configPath = Join-Path $RootPath "config/awf-codegraph.config.json"
    if (Test-Path -LiteralPath $configPath) {
        try {
            return Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            Write-AwfWarn "Failed to read config at $configPath. Using built-in defaults."
        }
    }

    return Get-AwfDefaultConfig
}
```

- [ ] **Step 3: Add command discovery helper**

Append this function to `src/Awf.Util.psm1`:

```powershell
function Test-AwfCommandAvailable {
    param([Parameter(Mandatory)][string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    return ($null -ne $command)
}
```

- [ ] **Step 4: Verify helpers load**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module .\src\Awf.Util.psm1 -Force; (Get-AwfDefaultConfig).graph.indexer; Test-AwfCommandAvailable -Name powershell"
```

Expected: Output includes `powershell-regex-mvp` and `True`.

## Task 3: Config-Driven File Discovery With Optional `rg`

**Files:**
- Modify: `src/Awf.Git.psm1`
- Modify: `src/Awf.CodeGraph.psm1`

- [ ] **Step 1: Change `Get-AwfChangedFiles` signature**

In `src/Awf.Git.psm1`, replace the `Get-AwfChangedFiles` function with:

```powershell
function Get-AwfChangedFiles {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [string[]]$Extensions = @(".cs", ".ts", ".tsx", ".js", ".jsx", ".py", ".json", ".csproj", ".sln", ".props", ".targets")
    )

    $extensionSet = @{}
    foreach ($ext in $Extensions) { $extensionSet[$ext.ToLowerInvariant()] = $true }

    $old = Get-Location
    try {
        Set-Location $RepoPath

        $files = @()
        $tracked = git diff --name-only HEAD 2>$null
        $staged = git diff --name-only --cached 2>$null
        $untracked = git ls-files --others --exclude-standard 2>$null

        $files += $tracked
        $files += $staged
        $files += $untracked

        $files |
            Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $RepoPath $_)) } |
            Where-Object {
                $ext = [System.IO.Path]::GetExtension($_).ToLowerInvariant()
                $extensionSet.ContainsKey($ext)
            } |
            Sort-Object -Unique
    }
    finally {
        Set-Location $old
    }
}
```

- [ ] **Step 2: Change `Get-AwfRepoFiles` signature**

In `src/Awf.Git.psm1`, replace the `Get-AwfRepoFiles` function with:

```powershell
function Get-AwfRepoFiles {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [string[]]$Extensions = @(".cs", ".ts", ".tsx", ".js", ".jsx", ".py", ".json", ".csproj", ".sln", ".props", ".targets"),
        [string[]]$ExcludeDirectories = @(".git", ".wi", "node_modules", "bin", "obj", "dist", "build"),
        [switch]$UsePowerShellFallback
    )

    $extensionSet = @{}
    foreach ($ext in $Extensions) { $extensionSet[$ext.ToLowerInvariant()] = $true }

    $excludePattern = "([\\/])(" + (($ExcludeDirectories | ForEach-Object { [regex]::Escape($_) }) -join "|") + ")([\\/])"

    if (!$UsePowerShellFallback -and (Test-AwfCommandAvailable -Name "rg")) {
        $old = Get-Location
        try {
            Set-Location $RepoPath
            return @(rg --files | Where-Object {
                $ext = [System.IO.Path]::GetExtension($_).ToLowerInvariant()
                $extensionSet.ContainsKey($ext) -and ($_ -notmatch $excludePattern)
            } | Sort-Object -Unique)
        }
        finally {
            Set-Location $old
        }
    }

    Get-ChildItem -LiteralPath $RepoPath -Recurse -File |
        Where-Object {
            $relativePath = [System.IO.Path]::GetRelativePath($RepoPath, $_.FullName)
            ($_.FullName -notmatch $excludePattern) -and
            $extensionSet.ContainsKey($_.Extension.ToLowerInvariant())
        } |
        ForEach-Object {
            [System.IO.Path]::GetRelativePath($RepoPath, $_.FullName)
        } |
        Sort-Object -Unique
}
```

- [ ] **Step 3: Add discovery method helper**

Append this function to `src/Awf.Git.psm1`:

```powershell
function Get-AwfFileDiscoveryMethod {
    if (Test-AwfCommandAvailable -Name "rg") {
        return "rg"
    }

    return "powershell"
}
```

- [ ] **Step 4: Pass config from `Update-AwfCodeGraph`**

In `src/Awf.CodeGraph.psm1`, at the start of `Update-AwfCodeGraph` after `$graph = ...`, add:

```powershell
$toolRoot = Split-Path -Parent $PSScriptRoot
$config = Get-AwfConfig -RootPath $toolRoot
$extensions = @($config.graph.extensions)
$excludeDirectories = @($config.graph.excludeDirectories)
$fileDiscovery = if ($ChangedOnly) { "git" } else { Get-AwfFileDiscoveryMethod }
```

Then replace:

```powershell
$relativeFiles = @(Get-AwfChangedFiles -RepoPath $RepoPath)
```

with:

```powershell
$relativeFiles = @(Get-AwfChangedFiles -RepoPath $RepoPath -Extensions $extensions)
```

And replace:

```powershell
$relativeFiles = @(Get-AwfRepoFiles -RepoPath $RepoPath)
```

with:

```powershell
$relativeFiles = @(Get-AwfRepoFiles -RepoPath $RepoPath -Extensions $extensions -ExcludeDirectories $excludeDirectories)
```

- [ ] **Step 5: Record discovery method in graph state**

In the final state object in `Update-AwfCodeGraph`, add:

```powershell
fileDiscovery = $fileDiscovery
```

Expected state keys include `version`, `lastUpdatedUtc`, `changedOnly`, `indexedFileCount`, `indexer`, and `fileDiscovery`.

- [ ] **Step 6: Verify full update**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\awf.ps1 update -RepoPath . -VerboseOutput
Get-Content .\.wi\graph\graph-state.json
```

Expected: graph files are written and `graph-state.json` includes `"fileDiscovery"`.

- [ ] **Step 7: Verify changed-only update still works**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\awf.ps1 update -RepoPath . -ChangedOnly
Get-Content .\.wi\graph\graph-state.json
```

Expected: command completes. In this non-git workspace it may warn that no changed source files were detected; in a git workspace the state uses `"fileDiscovery": "git"`.

## Task 4: Dual Markdown And JSON Context Packets

**Files:**
- Modify: `src/Awf.ContextPacket.psm1`

- [ ] **Step 1: Add context model builder**

In `src/Awf.ContextPacket.psm1`, before `New-AwfContextPacket`, add:

```powershell
function New-AwfContextModel {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$TaskFile,
        [string]$Query
    )

    $toolRoot = Split-Path -Parent $PSScriptRoot
    $config = Get-AwfConfig -RootPath $toolRoot
    $graph = Join-Path $RepoPath ".wi/graph"

    $taskText = ""
    $taskObject = $null
    if ($TaskFile) {
        $taskPath = if (Test-Path -LiteralPath $TaskFile) { $TaskFile } else { Join-Path $RepoPath $TaskFile }
        if (Test-Path -LiteralPath $taskPath) {
            $taskText = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8
            try { $taskObject = $taskText | ConvertFrom-Json } catch { $taskObject = $taskText.Trim() }
        }
        else {
            throw "Task file not found: $TaskFile"
        }
    }

    $changedPath = Join-Path $graph "changed-files.txt"
    $changed = if (Test-Path -LiteralPath $changedPath) {
        @(Get-Content -LiteralPath $changedPath -Encoding UTF8 | Where-Object { $_ })
    } else {
        @()
    }

    $files = @(Read-AwfJsonLines (Join-Path $graph "files.jsonl") | Sort-Object path)
    $symbols = @(Read-AwfJsonLines (Join-Path $graph "symbols.jsonl") | Sort-Object file, startLine, name)
    $summaries = @(Read-AwfJsonLines (Join-Path $graph "summaries.jsonl") | Sort-Object file)
    $graphStatePath = Join-Path $graph "graph-state.json"
    $graphState = if (Test-Path -LiteralPath $graphStatePath) {
        Get-Content -LiteralPath $graphStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        $null
    }

    $queryMatches = @()
    if (![string]::IsNullOrWhiteSpace($Query)) {
        $queryMatches = @(Search-AwfCodeGraph -RepoPath $RepoPath -Query $Query)
    }

    $changedNorm = @($changed | ForEach-Object { $_.Replace("\","/") } | Sort-Object -Unique)
    $changedSymbols = @($symbols | Where-Object { $changedNorm -contains $_.file })

    $candidateFiles = @()
    $candidateFiles += $changedNorm
    $candidateFiles += @($queryMatches | ForEach-Object { $_.file })
    $candidateFiles += @($changedSymbols | ForEach-Object { $_.file })
    $candidateFiles = @($candidateFiles | Where-Object { $_ } | Sort-Object -Unique)

    if ($candidateFiles.Count -eq 0 -and $files.Count -gt 0) {
        $candidateFiles = @($files | Select-Object -First $config.contextPacket.maxRecommendedFiles | ForEach-Object { $_.path })
    }

    $relevantSymbols = @($symbols | Where-Object { $candidateFiles -contains $_.file } | Select-Object -First $config.contextPacket.maxSymbols)
    $relevantSummaries = @($summaries | Where-Object { $candidateFiles -contains $_.file } | Select-Object -First $config.contextPacket.maxSummaries)
    $recommendedFiles = @($candidateFiles | Select-Object -First $config.contextPacket.maxRecommendedFiles)

    [pscustomobject]@{
        generatedUtc = (Get-Date).ToUniversalTime().ToString("o")
        repoPath = $RepoPath
        task = $taskObject
        taskText = $taskText
        query = $Query
        changedFiles = $changedNorm
        recommendedFiles = $recommendedFiles
        symbols = $relevantSymbols
        summaries = $relevantSummaries
        limits = [pscustomobject]@{
            maxSymbols = $config.contextPacket.maxSymbols
            maxSummaries = $config.contextPacket.maxSummaries
            maxRecommendedFiles = $config.contextPacket.maxRecommendedFiles
        }
        graphState = $graphState
    }
}
```

- [ ] **Step 2: Refactor `New-AwfContextPacket` to use the model**

At the start of `New-AwfContextPacket`, after ensuring `$runtime`, add:

```powershell
$model = New-AwfContextModel -RepoPath $RepoPath -TaskFile $TaskFile -Query $Query
```

Then replace references to local `$taskText`, `$changedNorm`, `$relevantSymbols`, `$relevantSummaries`, and `$candidateFiles` with `$model.taskText`, `$model.changedFiles`, `$model.symbols`, `$model.summaries`, and `$model.recommendedFiles`.

- [ ] **Step 3: Write JSON packet**

Before returning from `New-AwfContextPacket`, add:

```powershell
$jsonOut = Join-Path $runtime "context-packet.json"
$model |
    Select-Object generatedUtc, repoPath, task, query, changedFiles, recommendedFiles, symbols, summaries, limits, graphState |
    ConvertTo-Json -Depth 50 |
    Set-Content -LiteralPath $jsonOut -Encoding UTF8
```

- [ ] **Step 4: Verify context outputs**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\awf.ps1 update -RepoPath .
powershell -NoProfile -ExecutionPolicy Bypass -File .\awf.ps1 context -RepoPath . -Query "Awf"
Test-Path .\.wi\runtime\context-packet.md
Test-Path .\.wi\runtime\context-packet.json
Get-Content .\.wi\runtime\context-packet.json -Raw | ConvertFrom-Json | Select-Object generatedUtc, query
```

Expected: Both `Test-Path` commands return `True`, and parsed JSON shows `query` as `Awf`.

## Task 5: User-Level Installer And `awf-graph` Launcher

**Files:**
- Modify: `scripts/install.ps1`

- [ ] **Step 1: Replace installer parameters**

Replace the current `param(...)` block in `scripts/install.ps1` with:

```powershell
[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA "AWF/CodeGraph"),
    [switch]$SkipOptionalTools
)
```

- [ ] **Step 2: Replace repo-copy install logic**

Replace the body after `$ErrorActionPreference = "Stop"` with:

```powershell
$sourceRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$toolRoot = Join-Path $InstallRoot "toolkit"
$binRoot = Join-Path $InstallRoot "bin"

New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null
New-Item -ItemType Directory -Force -Path $binRoot | Out-Null

Copy-Item -LiteralPath (Join-Path $sourceRoot "awf.ps1") -Destination $toolRoot -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "src") -Destination $toolRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "templates") -Destination $toolRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "docs") -Destination $toolRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "config") -Destination $toolRoot -Recurse -Force

$launcherPath = Join-Path $binRoot "awf-graph.ps1"
$launcher = @"
param(
    [Parameter(ValueFromRemainingArguments=`$true)]
    [string[]]`$RemainingArgs
)

`$tool = Join-Path "$toolRoot" "awf.ps1"
& powershell -NoProfile -ExecutionPolicy Bypass -File `$tool @RemainingArgs
exit `$LASTEXITCODE
"@
Set-Content -LiteralPath $launcherPath -Value $launcher -Encoding UTF8
```

- [ ] **Step 3: Add user PATH helper**

Append this code in `scripts/install.ps1` after launcher creation:

```powershell
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$pathParts = @($userPath -split ";" | Where-Object { $_ })
if ($pathParts -notcontains $binRoot) {
    [Environment]::SetEnvironmentVariable("Path", (($pathParts + $binRoot) -join ";"), "User")
    Write-Host "Added $binRoot to the current user's PATH. Open a new shell before running awf-graph globally." -ForegroundColor Yellow
}
```

- [ ] **Step 4: Add optional tool installer prompt**

Append this code in `scripts/install.ps1`:

```powershell
function Install-AwfOptionalTool {
    param(
        [Parameter(Mandatory)][string]$CommandName,
        [Parameter(Mandatory)][string]$WingetId,
        [Parameter(Mandatory)][string]$Reason
    )

    if ($SkipOptionalTools) { return }
    if (Get-Command $CommandName -ErrorAction SilentlyContinue) { return }
    if (!(Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "Optional tool '$CommandName' is missing. $Reason Install skipped because winget is unavailable." -ForegroundColor Yellow
        return
    }

    Write-Host "Optional tool '$CommandName' is missing. $Reason" -ForegroundColor Cyan
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
```

- [ ] **Step 5: Add install summary**

Append this code to the end of `scripts/install.ps1`:

```powershell
Write-Host "Installed AWF Code Graph Toolkit into $toolRoot" -ForegroundColor Green
Write-Host "Launcher created at $launcherPath" -ForegroundColor Green
Write-Host "Run from any project in a new shell:" -ForegroundColor Cyan
Write-Host "  awf-graph init"
Write-Host "  awf-graph update"
Write-Host "  awf-graph context -Query `"keyword`""
```

- [ ] **Step 6: Verify installer without optional tools**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1 -InstallRoot "$env:TEMP\awf-codegraph-install-test" -SkipOptionalTools
& "$env:TEMP\awf-codegraph-install-test\bin\awf-graph.ps1" status -RepoPath .
```

Expected: Installer prints created paths, and launcher prints AWF status.

## Task 6: Documentation Updates

**Files:**
- Modify: `README.md`
- Modify: `templates/agent-instructions.md`

- [ ] **Step 1: Update README command examples**

In `README.md`, replace command examples using `.\awf.ps1 graph ...` with:

```powershell
awf-graph init
awf-graph update
awf-graph update -ChangedOnly
awf-graph impact
awf-graph context -TaskFile ".\examples\sample-task.json"
awf-graph query -Query "StudentService"
```

- [ ] **Step 2: Update README installer section**

Replace the repo-local install section with:

```powershell
.\scripts\install.ps1
```

Then document:

```text
The installer creates a user-level awf-graph command. Optional tools such as rg and gh are detected during install. Missing optional tools are only installed with explicit consent through winget.
```

- [ ] **Step 3: Update agent instructions**

In `templates/agent-instructions.md`, replace:

```powershell
.\.wi\tools\awf-codegraph\awf.ps1 graph update -RepoPath . -ChangedOnly
```

with:

```powershell
awf-graph update -ChangedOnly
```

And replace:

```powershell
.\.wi\tools\awf-codegraph\awf.ps1 graph impact -RepoPath .
```

with:

```powershell
awf-graph impact
```

- [ ] **Step 4: Verify docs do not recommend repo-local installation as primary UX**

Run:

```powershell
Select-String -Path README.md,templates/agent-instructions.md -Pattern '\\.wi\\tools\\awf-codegraph|awf.ps1 graph'
```

Expected: no matches in primary user instructions.

## Task 7: Final Verification

**Files:**
- Verify: `awf.ps1`
- Verify: `src/Awf.Util.psm1`
- Verify: `src/Awf.Git.psm1`
- Verify: `src/Awf.CodeGraph.psm1`
- Verify: `src/Awf.ContextPacket.psm1`
- Verify: `scripts/install.ps1`
- Verify: `README.md`
- Verify: `templates/agent-instructions.md`

- [ ] **Step 1: Clean generated test graph**

Run:

```powershell
if (Test-Path .\.wi) { Remove-Item .\.wi -Recurse -Force }
```

Expected: `.wi` does not exist after the command.

- [ ] **Step 2: Run init/update/status**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\awf.ps1 init -RepoPath .
powershell -NoProfile -ExecutionPolicy Bypass -File .\awf.ps1 update -RepoPath . -VerboseOutput
powershell -NoProfile -ExecutionPolicy Bypass -File .\awf.ps1 status -RepoPath .
```

Expected: `.wi/graph` exists, files are indexed, and status reports nonzero file/symbol/edge counts.

- [ ] **Step 3: Run context and parse JSON**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\awf.ps1 context -RepoPath . -Query "CodeGraph"
$packet = Get-Content .\.wi\runtime\context-packet.json -Raw | ConvertFrom-Json
$packet.recommendedFiles.Count
$packet.limits.maxRecommendedFiles
```

Expected: JSON parses, recommended file count is not greater than `maxRecommendedFiles`.

- [ ] **Step 4: Run impact**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\awf.ps1 impact -RepoPath .
Test-Path .\.wi\graph\impact.md
```

Expected: `Test-Path` returns `True`.

- [ ] **Step 5: Run installer verification**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1 -InstallRoot "$env:TEMP\awf-codegraph-install-test" -SkipOptionalTools
& "$env:TEMP\awf-codegraph-install-test\bin\awf-graph.ps1" update -RepoPath .
```

Expected: launcher runs successfully and updates the graph in the current project.

- [ ] **Step 6: Self-review generated context for AI usefulness**

Open:

```powershell
Get-Content .\.wi\runtime\context-packet.md
Get-Content .\.wi\runtime\context-packet.json -Raw | ConvertFrom-Json
```

Expected:

- Markdown recommends bounded files to read first.
- JSON includes `generatedUtc`, `repoPath`, `recommendedFiles`, `symbols`, `summaries`, `limits`, and `graphState`.
- No full source file contents are embedded by default.

- [ ] **Step 7: Commit if git is available**

Run:

```powershell
git rev-parse --is-inside-work-tree
```

Expected in this workspace today: failure because this folder is not a git repository.

If git is initialized later, run:

```powershell
git add awf.ps1 src/Awf.Util.psm1 src/Awf.Git.psm1 src/Awf.CodeGraph.psm1 src/Awf.ContextPacket.psm1 scripts/install.ps1 README.md templates/agent-instructions.md docs/superpowers/plans/2026-05-23-awf-graph-global-command.md
git commit -m "feat: add global awf-graph workflow"
```

## Self-Review

- Spec coverage: This plan covers the `awf-graph` command shape, user-level installer, optional `winget` dependency prompts, `rg`-accelerated scanning, config-driven limits, Markdown and JSON context packets, graph freshness metadata, docs, and verification.
- Placeholder scan: The plan contains no TBD/TODO placeholders and no vague implementation-only steps.
- Type consistency: Function names introduced here are consistent across tasks: `Get-AwfDefaultConfig`, `Get-AwfConfig`, `Test-AwfCommandAvailable`, `Get-AwfFileDiscoveryMethod`, and `New-AwfContextModel`.

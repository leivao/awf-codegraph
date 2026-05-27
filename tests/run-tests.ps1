[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$null = Import-Module (Join-Path $repoRoot "src/Awf.CodeGraph.psm1") -Force -Global
$null = Import-Module (Join-Path $repoRoot "src/Awf.ContextPacket.psm1") -Force -Global
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

Invoke-Test "CLI update accepts an explicit Roslyn indexer selector" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-roslyn-selector-test-" + [guid]::NewGuid().ToString("N"))
    try {
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-sample") $repoPath

        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath

        $statePath = Join-Path $repoPath ".wi/graph/graph-state.json"
        Assert-PathExists -Path $statePath -Message "Roslyn update should write graph-state.json."

        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True -Condition ($state.indexer -eq "roslyn") -Message "Graph state should record the Roslyn indexer."

        $statusText = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") status -RepoPath $repoPath | Out-String
        Assert-True -Condition ($statusText -match "roslyn") -Message "Status output should surface the last-used Roslyn indexer."
    }
    finally {
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}

Invoke-Test "CLI update respects the configured default indexer when omitted" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-roslyn-config-default-test-" + [guid]::NewGuid().ToString("N"))
    $toolkitRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-roslyn-toolkit-" + [guid]::NewGuid().ToString("N"))
    $toolkitConfigPath = Join-Path $toolkitRoot "config/awf-codegraph.config.json"
    try {
        New-Item -ItemType Directory -Force -Path $toolkitRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $repoRoot "awf.ps1") -Destination $toolkitRoot
        Copy-Item -Recurse -Force -LiteralPath (Join-Path $repoRoot "src") -Destination $toolkitRoot
        Copy-Item -Recurse -Force -LiteralPath (Join-Path $repoRoot "config") -Destination $toolkitRoot
        Copy-Item -Recurse -Force -LiteralPath (Join-Path $repoRoot "tools") -Destination $toolkitRoot

        $originalConfig = Get-Content -LiteralPath $toolkitConfigPath -Raw -Encoding UTF8
        $config = $originalConfig | ConvertFrom-Json
        $config.graph.indexer = "roslyn"
        ($config | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $toolkitConfigPath -Encoding UTF8

        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-sample") $repoPath

        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $toolkitRoot "awf.ps1") update -RepoPath $repoPath

        $statePath = Join-Path $repoPath ".wi/graph/graph-state.json"
        Assert-PathExists -Path $statePath -Message "Update should write graph-state.json."

        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True -Condition ($state.indexer -eq "roslyn") -Message "Configured default indexer should be honored when -Indexer is omitted."
    }
    finally {
        if (Test-Path -LiteralPath $toolkitRoot) {
            Remove-Item -LiteralPath $toolkitRoot -Recurse -Force
        }
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}

Invoke-Test "Roslyn tool emits JSONL graph files for a small C# solution" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-roslyn-tool-test-" + [guid]::NewGuid().ToString("N"))
    $outPath = Join-Path $repoPath ".wi/graph"
    try {
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-sample") $repoPath
        & dotnet run --project (Join-Path $repoRoot "tools/Awf.CodeGraph.RoslynIndexer") -- --repo $repoPath --solution (Join-Path $repoPath "RoslynSample.sln") --output $outPath

        Assert-PathExists -Path (Join-Path $outPath "files.jsonl") -Message "Roslyn tool should write files.jsonl."
        Assert-PathExists -Path (Join-Path $outPath "symbols.jsonl") -Message "Roslyn tool should write symbols.jsonl."
        Assert-PathExists -Path (Join-Path $outPath "edges.jsonl") -Message "Roslyn tool should write edges.jsonl."
        Assert-PathExists -Path (Join-Path $outPath "summaries.jsonl") -Message "Roslyn tool should write summaries.jsonl."
        Assert-PathExists -Path (Join-Path $outPath "graph-state.json") -Message "Roslyn tool should write graph-state.json."

        $state = Get-Content -LiteralPath (Join-Path $outPath "graph-state.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True -Condition ($state.indexer -eq "roslyn") -Message "Roslyn tool should record the Roslyn indexer in graph state."
        Assert-True -Condition ($state.indexedFileCount -eq 1) -Message "Roslyn tool should only index the sample source file."

        $filesText = Get-Content -LiteralPath (Join-Path $outPath "files.jsonl") -Raw -Encoding UTF8
        Assert-True -Condition ($filesText -match "Class1\.cs") -Message "Roslyn tool should index the sample class file."
        Assert-True -Condition ($filesText -notmatch "/obj/|/bin/") -Message "Roslyn tool should exclude generated obj and bin documents."

        $files = @(Get-Content -LiteralPath (Join-Path $outPath "files.jsonl") -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $symbolsText = Get-Content -LiteralPath (Join-Path $outPath "symbols.jsonl") -Raw -Encoding UTF8
        Assert-True -Condition ($symbolsText -match "Class1") -Message "Roslyn tool should index the sample C# class."

        $symbols = @(Get-Content -LiteralPath (Join-Path $outPath "symbols.jsonl") -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $summaries = @(Get-Content -LiteralPath (Join-Path $outPath "summaries.jsonl") -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })

        Assert-True -Condition (@($files | Where-Object { $_.path -eq "src/RoslynSample/Class1.cs" -and $_.source -eq "roslyn" -and $_.confidence -eq "high" -and $_.indexedUtc }).Count -gt 0) -Message "Roslyn files should carry source, confidence, and indexedUtc metadata."
        Assert-True -Condition (@($symbols | Where-Object { $_.file -eq "src/RoslynSample/Class1.cs" -and $_.source -eq "roslyn" -and $_.confidence -eq "high" -and $_.indexedUtc }).Count -gt 0) -Message "Roslyn symbols should carry source, confidence, and indexedUtc metadata."
        Assert-True -Condition (@($summaries | Where-Object { $_.file -eq "src/RoslynSample/Class1.cs" -and $_.source -eq "roslyn" -and $_.confidence -eq "high" -and $_.indexedUtc }).Count -gt 0) -Message "Roslyn summaries should carry source, confidence, and indexedUtc metadata."
    }
    finally {
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}

Invoke-Test "Roslyn tool emits semantic edges for a representative C# project" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-roslyn-semantics-test-" + [guid]::NewGuid().ToString("N"))
    $outPath = Join-Path $repoPath ".wi/graph"
    try {
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-semantics-sample") $repoPath
        & dotnet run --project (Join-Path $repoRoot "tools/Awf.CodeGraph.RoslynIndexer") -- --repo $repoPath --solution (Join-Path $repoPath "RoslynSemanticsSample.sln") --output $outPath

        $edges = @(Get-Content -LiteralPath (Join-Path $outPath "edges.jsonl") -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-True -Condition (@($edges | Where-Object { $_.type -eq "inherits" }).Count -gt 0) -Message "Roslyn should emit inherits edges."
        Assert-True -Condition (@($edges | Where-Object { $_.type -eq "implements" }).Count -gt 0) -Message "Roslyn should emit implements edges."
        Assert-True -Condition (@($edges | Where-Object { $_.type -eq "invokes" }).Count -gt 0) -Message "Roslyn should emit invokes edges."
        Assert-True -Condition (@($edges | Where-Object { $_.type -eq "references" }).Count -gt 0) -Message "Roslyn should emit references edges."
        Assert-True -Condition (@($edges | Where-Object { $_.type -eq "parameter-types" }).Count -gt 0) -Message "Roslyn should emit parameter-types edges."
        Assert-True -Condition (@($edges | Where-Object { $_.type -eq "returns" }).Count -gt 0) -Message "Roslyn should emit returns edges."
        Assert-True -Condition (@($edges | Where-Object { $_.to -match '\?' }).Count -eq 0) -Message "Semantic edge targets should not include nullable annotations."
        Assert-True -Condition (@($edges | Where-Object { $_.to -like 'symbol:metadata:*' }).Count -eq 0) -Message "Semantic edge targets should only point at source-backed symbols."
        Assert-True -Condition (@($edges | Where-Object { $_.type -eq "inherits" -and $_.to -match '#RoslynSemanticsSample.BaseService$' }).Count -gt 0) -Message "Inheritance should target BaseService."
        Assert-True -Condition (@($edges | Where-Object { $_.type -eq "inherits" -and $_.to -match '#RoslynSemanticsSample.IService$' }).Count -gt 0) -Message "Interface inheritance should target IService."
        Assert-True -Condition (@($edges | Where-Object { $_.type -eq "implements" -and $_.to -match '#RoslynSemanticsSample.IService$' }).Count -gt 0) -Message "Implements should target IService."
        Assert-True -Condition (@($edges | Where-Object { $_.type -eq "parameter-types" -and $_.to -match '#RoslynSemanticsSample.IService$' }).Count -eq 1) -Message "Parameter types should target IService once."
        Assert-True -Condition (@($edges | Where-Object { $_.type -eq "parameter-types" -and $_.to -match '#RoslynSemanticsSample.Service$' }).Count -eq 1) -Message "Wrapped parameter types should target Service once."
        Assert-True -Condition (@($edges | Where-Object { $_.type -eq "references" -and $_.to -match '#RoslynSemanticsSample.Service$' }).Count -eq 4) -Message "References should dedupe Service to one edge per method."
        Assert-True -Condition (@($edges | Where-Object { $_.type -eq "returns" -and $_.to -match '#RoslynSemanticsSample.Service$' }).Count -eq 3) -Message "Returns should target Service three times, including wrapped Task<Service>."
        Assert-True -Condition (@($edges | Where-Object { $_.type -eq "invokes" -and $_.to -match '#RoslynSemanticsSample.Service.Execute\(string\)$' }).Count -gt 0) -Message "Invokes should target Service.Execute(string)."
        Assert-True -Condition (@($edges | Where-Object { $_.type -eq "invokes" -and $_.to -match '#RoslynSemanticsSample.IService.Execute\(string\)$' }).Count -gt 0) -Message "Invokes should target IService.Execute(string)."
        Assert-True -Condition (@($edges | Where-Object { $_.type -eq "invokes" -and $_.from -match 'Consumer\.cs$' }).Count -eq 5) -Message "Constructor calls and method calls should yield five Consumer.cs invokes."
        Assert-True -Condition (@($edges | Where-Object { $_.type -eq "references" -and $_.to -match '#RoslynSemanticsSample.Service$' -and $_.from -match 'Consumer\.cs$' }).Count -eq 4) -Message "Static member access and object construction should yield four deduped Service references from Consumer.cs."
        Assert-True -Condition (@($edges | Where-Object { $_.source -eq "roslyn" -and $_.confidence -eq "high" }).Count -eq $edges.Count) -Message "Roslyn semantic edges should carry source and confidence metadata."
    }
    finally {
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}

Invoke-Test "Roslyn tool classifies common .NET app shapes and test files" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-roslyn-framework-test-" + [guid]::NewGuid().ToString("N"))
    $outPath = Join-Path $repoPath ".wi/graph"
    try {
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-framework-sample") $repoPath
        & dotnet run --project (Join-Path $repoRoot "tools/Awf.CodeGraph.RoslynIndexer") -- --repo $repoPath --solution (Join-Path $repoPath "RoslynFrameworkSample.sln") --output $outPath

        $files = @(Get-Content -LiteralPath (Join-Path $outPath "files.jsonl") -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-True -Condition (@($files | Where-Object { $_.kind -eq "api-controller" }).Count -gt 0) -Message "Controller files should be classified."
        Assert-True -Condition (@($files | Where-Object { $_.kind -eq "test" }).Count -gt 0) -Message "Test files should be classified."
        Assert-True -Condition (@($files | Where-Object { $_.path -eq "src/Harness/Support.cs" -and $_.kind -eq "test" }).Count -eq 1) -Message "Project-name-based test files should be classified as test."
        Assert-True -Condition (@($files | Where-Object { $_.path -eq "src/ContestApp/ContestMarker.cs" -and $_.kind -eq "source" }).Count -eq 1) -Message "ContestApp should not be misclassified as a test project."
    }
    finally {
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}

Invoke-Test "Roslyn update keeps non-C# files in the graph" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-roslyn-mixed-test-" + [guid]::NewGuid().ToString("N"))
    try {
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-sample") $repoPath
        Set-Content -LiteralPath (Join-Path $repoPath "notes.txt") -Value "keep me" -Encoding UTF8

        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath

        $graphPath = Join-Path $repoPath ".wi/graph"
        $files = @(Get-Content -LiteralPath (Join-Path $graphPath "files.jsonl") -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-True -Condition (@($files | Where-Object { $_.path -eq "notes.txt" }).Count -gt 0) -Message "Non-C# files should still be indexed by the PowerShell path."
        Assert-True -Condition (@($files | Where-Object { $_.path -eq "src/RoslynSample/Class1.cs" }).Count -gt 0) -Message "C# files should still appear in the combined graph."
        Assert-True -Condition (@($files | Where-Object { $_.path -match "/obj/|/bin/" }).Count -eq 0) -Message "Generated C# documents should not be merged into the main graph."

        $symbols = @(Get-Content -LiteralPath (Join-Path $graphPath "symbols.jsonl") -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-True -Condition (@($symbols | Where-Object { $_.file -eq "src/RoslynSample/Class1.cs" }).Count -gt 0) -Message "Roslyn C# symbols should be merged into the main graph."
        Assert-True -Condition (@($symbols | Where-Object { $_.file -eq "notes.txt" }).Count -eq 0) -Message "Non-code text files should not produce symbol entries."

        $summaries = @(Get-Content -LiteralPath (Join-Path $graphPath "summaries.jsonl") -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-True -Condition (@($summaries | Where-Object { $_.file -eq "notes.txt" }).Count -gt 0) -Message "Non-C# files should retain PowerShell summaries."
        Assert-True -Condition (@($summaries | Where-Object { $_.file -eq "src/RoslynSample/Class1.cs" }).Count -gt 0) -Message "Roslyn C# files should retain merged summaries."

        $state = Get-Content -LiteralPath (Join-Path $graphPath "graph-state.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True -Condition ([bool]($state.indexer -eq "roslyn")) -Message "Graph state should stay aligned with the selected Roslyn indexer."
    }
    finally {
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}

Invoke-Test "Graph retrieval ranks blast radius, tests, and context packets" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-retrieval-test-" + [guid]::NewGuid().ToString("N"))
    try {
        Import-Module (Join-Path $repoRoot "src/Awf.CodeGraph.psm1") -Force
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-framework-sample") $repoPath
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath

        $graphPath = Join-Path $repoPath ".wi/graph"
        $packet = Get-AwfGraphContextPacket -GraphPath $graphPath -Seed "src/RoslynFrameworkSample/ServiceCollectionExtensions.cs" -Budget 10

        Assert-True -Condition ([bool]$packet) -Message "Retrieval should return a packet object."
        Assert-True -Condition ($packet.primary -eq "src/RoslynFrameworkSample/ServiceCollectionExtensions.cs") -Message "The packet should preserve the seed."
        Assert-True -Condition (@($packet.blastRadius | Where-Object { $_.path -eq "src/RoslynFrameworkSample/ServiceCollectionExtensions.cs" }).Count -gt 0) -Message "Blast radius should include the seed file."
        Assert-True -Condition (@($packet.relatedTests | Where-Object { $_.path -like "*tests*" }).Count -gt 0) -Message "Related tests should be ranked into the packet."
        Assert-True -Condition ($packet.contextFiles.Count -le 10) -Message "Context packet should stay bounded."
    }
    finally {
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}

Invoke-Test "Roslyn update fails clearly when no solution is available" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-roslyn-nosln-test-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Force -Path (Join-Path $repoPath ".git") | Out-Null
        Set-Content -LiteralPath (Join-Path $repoPath "Sample.cs") -Value "namespace Demo; public class Sample { public void Run() {} }" -Encoding UTF8

        $failed = $false
        $outputText = ""
        try {
            $outputText = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath 2>&1 | Out-String)
            $failed = ($LASTEXITCODE -ne 0)
        }
        catch {
            $failed = $true
            $outputText = $_ | Out-String
        }

        Assert-True -Condition ([bool]$failed) -Message "Roslyn update should fail when no solution is available."
        Assert-True -Condition ([bool]($outputText -match "\.sln")) -Message "Roslyn failure should clearly mention the missing solution requirement."
    }
    finally {
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}

Invoke-Test "Graph retrieval fails clearly when graph artifacts are missing" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-retrieval-missing-test-" + [guid]::NewGuid().ToString("N"))
    try {
        Import-Module (Join-Path $repoRoot "src/Awf.CodeGraph.psm1") -Force
        New-Item -ItemType Directory -Force -Path (Join-Path $repoPath ".wi/graph") | Out-Null

        $failed = $false
        $message = ""
        try {
            Get-AwfGraphContextPacket -GraphPath (Join-Path $repoPath ".wi/graph") -Seed "src/RoslynFrameworkSample/ServiceCollectionExtensions.cs"
        }
        catch {
            $failed = $true
            $message = $_.Exception.Message
        }

        Assert-True -Condition $failed -Message "Retrieval should fail when the graph is incomplete."
        Assert-True -Condition ($message -match "files\.jsonl|symbols\.jsonl|edges\.jsonl|summaries\.jsonl") -Message "The error should name the missing graph artifacts."
    }
    finally {
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}

Invoke-Test "Context packet evaluation helper returns deterministic metrics" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-context-eval-test-" + [guid]::NewGuid().ToString("N"))
    try {
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-framework-sample") $repoPath
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath

        $graphPath = Join-Path $repoPath ".wi/graph"
        $contextPacketModule = Get-Module Awf.ContextPacket
        $metrics = $contextPacketModule.Invoke({
            param($repoPath, $graphPath, $seed, $query, $budget)
            Get-AwfContextPacketEvaluation -RepoPath $repoPath -GraphPath $graphPath -Seed $seed -Query $query -Budget $budget
        }, @(
            $repoPath,
            $graphPath,
            "src/RoslynFrameworkSample/ServiceCollectionExtensions.cs",
            "ServiceCollectionExtensions",
            10
        ))

        Assert-True -Condition ([bool]$metrics) -Message "Evaluation helper should return a metrics object."
        Assert-True -Condition ($metrics.packetBytes -gt 0) -Message "Evaluation packet should have a non-zero size."
        Assert-True -Condition ($metrics.contextFileCount -le 10) -Message "Context file count should stay within the budget."
        Assert-True -Condition ($metrics.seed -eq "src/RoslynFrameworkSample/ServiceCollectionExtensions.cs") -Message "Evaluation should preserve the seed."
        Assert-True -Condition ($metrics.query -eq "ServiceCollectionExtensions") -Message "Evaluation should preserve the query."
    }
    finally {
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}

function Format-AwfContextPacketEvaluationMetrics {
    param(
        [Parameter(Mandatory)][string]$CaseName,
        [Parameter(Mandatory)]$Metrics
    )

    $topFiles = @($Metrics.topFiles) -join ";"
    $topTests = @($Metrics.topTests) -join ";"
    return "[$CaseName] seed=$($Metrics.seed) query=$($Metrics.query) baselineCount=$($Metrics.baselineCount) contextFileCount=$($Metrics.contextFileCount) relatedTestCount=$($Metrics.relatedTestCount) packetBytes=$($Metrics.packetBytes) topFiles=$topFiles topTests=$topTests"
}

Invoke-Test "Context packet evaluation benchmark matrix stays bounded and deterministic" {
    $cases = @(
        [pscustomobject]@{
            Name = "Symbol lookup"
            Fixture = "tests/fixtures/roslyn-framework-sample"
            Seed = "src/RoslynFrameworkSample/ServiceCollectionExtensions.cs"
            Query = "ServiceCollectionExtensions"
            Budget = 8
            MinimumRelatedTests = 0
            ExpectedTest = $null
        }
        [pscustomobject]@{
            Name = "Impact analysis"
            Fixture = "tests/fixtures/roslyn-semantics-sample"
            Seed = "src/RoslynSemanticsSample/Consumer.cs"
            Query = "Service"
            Budget = 8
            MinimumRelatedTests = 0
            ExpectedTest = $null
        }
        [pscustomobject]@{
            Name = "Endpoint tracing"
            Fixture = "tests/fixtures/roslyn-framework-sample"
            Seed = "src/RoslynFrameworkSample/ValuesController.cs"
            Query = "ValuesController"
            Budget = 8
            MinimumRelatedTests = 0
            ExpectedTest = $null
        }
        [pscustomobject]@{
            Name = "Test selection"
            Fixture = "tests/fixtures/roslyn-framework-sample"
            Seed = "src/RoslynFrameworkSample/ProductionService.cs"
            Query = "ProductionService"
            Budget = 8
            MinimumRelatedTests = 1
            ExpectedTest = "tests/TestServiceTests.cs"
        }
        [pscustomobject]@{
            Name = "Review targeting"
            Fixture = "tests/fixtures/roslyn-framework-sample"
            Seed = "src/RoslynFrameworkSample/RequestTimingMiddleware.cs"
            Query = "RequestTimingMiddleware"
            Budget = 8
            MinimumRelatedTests = 0
            ExpectedTest = $null
        }
    )

    foreach ($case in $cases) {
        $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-phase6-benchmark-" + [guid]::NewGuid().ToString("N"))
        try {
            Copy-Item -Recurse -Force (Join-Path $repoRoot $case.Fixture) $repoPath
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath

            Import-Module (Join-Path $repoRoot "src/Awf.ContextPacket.psm1") -Force -Global

            $graphPath = Join-Path $repoPath ".wi/graph"
            $contextPacketModule = Get-Module Awf.ContextPacket
            $metrics = $contextPacketModule.Invoke({
                param($repoPath, $graphPath, $seed, $query, $budget)
                Get-AwfContextPacketEvaluation -RepoPath $repoPath -GraphPath $graphPath -Seed $seed -Query $query -Budget $budget
            }, @(
                $repoPath,
                $graphPath,
                $case.Seed,
                $case.Query,
                $case.Budget
            ))

            $metricText = Format-AwfContextPacketEvaluationMetrics -CaseName $case.Name -Metrics $metrics
            $topFiles = @($metrics.topFiles)
            $topTests = @($metrics.topTests)

            Assert-True -Condition ([bool]$metrics) -Message "$metricText :: evaluation helper should return metrics."
            Assert-True -Condition ($metrics.seed -eq $case.Seed) -Message "$metricText :: seed should be preserved."
            Assert-True -Condition ($metrics.query -eq $case.Query) -Message "$metricText :: query should be preserved."
            Assert-True -Condition ($metrics.baselineCount -gt 0) -Message "$metricText :: baselineCount should capture raw query breadth."
            Assert-True -Condition ($metrics.packetBytes -gt 0 -and $metrics.packetBytes -le 4096) -Message "$metricText :: packetBytes should stay within the deterministic cap."
            Assert-True -Condition ($metrics.contextFileCount -le $case.Budget) -Message "$metricText :: contextFileCount should stay within budget $($case.Budget)."
            Assert-True -Condition (@($topFiles | Where-Object { $_ -eq $case.Seed }).Count -gt 0) -Message "$metricText :: the seed file should appear in topFiles."

            if ($case.MinimumRelatedTests -gt 0) {
                Assert-True -Condition ($metrics.relatedTestCount -ge $case.MinimumRelatedTests) -Message "$metricText :: relatedTestCount should be at least $($case.MinimumRelatedTests)."
            }

            if ($case.ExpectedTest) {
                Assert-True -Condition (@($topTests | Where-Object { $_ -eq $case.ExpectedTest }).Count -gt 0) -Message "$metricText :: expected test file '$($case.ExpectedTest)' should appear in topTests."
            }
        }
        finally {
            if (Test-Path -LiteralPath $repoPath) {
                Remove-Item -LiteralPath $repoPath -Recurse -Force
            }
        }
    }
}

Invoke-Test "Graph retrieval is deterministic for repeated calls" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-retrieval-deterministic-test-" + [guid]::NewGuid().ToString("N"))
    try {
        Import-Module (Join-Path $repoRoot "src/Awf.CodeGraph.psm1") -Force
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-framework-sample") $repoPath
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath

        $graphPath = Join-Path $repoPath ".wi/graph"
        $first = Get-AwfGraphContextPacket -GraphPath $graphPath -Seed "src/RoslynFrameworkSample/ServiceCollectionExtensions.cs" -Budget 10
        $second = Get-AwfGraphContextPacket -GraphPath $graphPath -Seed "src/RoslynFrameworkSample/ServiceCollectionExtensions.cs" -Budget 10
        $firstBlast = ($first.blastRadius | ForEach-Object { $_.path }) -join ";"
        $secondBlast = ($second.blastRadius | ForEach-Object { $_.path }) -join ";"
        $firstTests = ($first.relatedTests | ForEach-Object { $_.path }) -join ";"
        $secondTests = ($second.relatedTests | ForEach-Object { $_.path }) -join ";"
        $firstFiles = ($first.contextFiles | ForEach-Object { $_.path }) -join ";"
        $secondFiles = ($second.contextFiles | ForEach-Object { $_.path }) -join ";"

        Assert-True -Condition ($first.primary -eq $second.primary) -Message "Repeated retrieval calls should preserve the seed."
        Assert-True -Condition ($firstBlast -eq $secondBlast) -Message "Repeated retrieval calls should return the same blast-radius ordering."
        Assert-True -Condition ($firstTests -eq $secondTests) -Message "Repeated retrieval calls should return the same related-test ordering."
        Assert-True -Condition ($firstFiles -eq $secondFiles) -Message "Repeated retrieval calls should return the same packet file ordering."
    }
    finally {
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}

Invoke-Test "Roslyn update uses a standalone .csproj when no solution is available" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-roslyn-csproj-test-" + [guid]::NewGuid().ToString("N"))
    try {
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-sample") $repoPath
        Remove-Item -LiteralPath (Join-Path $repoPath "RoslynSample.sln") -Force

        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath

        $statePath = Join-Path $repoPath ".wi/graph/graph-state.json"
        Assert-PathExists -Path $statePath -Message "Roslyn update should succeed with only a .csproj."

        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True -Condition ($state.indexer -eq "roslyn") -Message "Standalone .csproj indexing should still record the Roslyn indexer."

        $files = @(Get-Content -LiteralPath (Join-Path $repoPath ".wi/graph/files.jsonl") -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-True -Condition (@($files | Where-Object { $_.path -eq "src/RoslynSample/Class1.cs" }).Count -gt 0) -Message "Standalone .csproj indexing should include the C# source file."
    }
    finally {
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}

Invoke-Test "Roslyn update marks stale graph sections when a partial refresh is unsafe" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-roslyn-stale-test-" + [guid]::NewGuid().ToString("N"))
    try {
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-framework-sample") $repoPath

        $old = Get-Location
        try {
            Set-Location $repoPath
            git init | Out-Null
            git config user.email "awf-test@example.test" | Out-Null
            git config user.name "AWF Test" | Out-Null
            git config commit.gpgsign false | Out-Null

            git add . | Out-Null
            git commit -m "Initial Roslyn framework sample" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Initial Roslyn framework test commit failed." }
        }
        finally {
            Set-Location $old
        }

        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath

        Set-Content -LiteralPath (Join-Path $repoPath "src/RoslynFrameworkSample/ServiceCollectionExtensions.cs") -Value 'namespace RoslynFrameworkSample; public static class ServiceCollectionExtensions { }' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $repoPath "src/RoslynFrameworkSample/ValuesController.cs") -Value 'namespace RoslynFrameworkSample; public sealed class ValuesController { }' -Encoding UTF8
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -ChangedOnly -Indexer roslyn -RepoPath $repoPath

        $state = Get-Content -LiteralPath (Join-Path $repoPath ".wi/graph/graph-state.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $staleSections = @($state.staleSections)
        Assert-True -Condition ($staleSections.Count -ge 2) -Message "Unsafe partial refreshes should mark both changed C# files as stale."
        Assert-True -Condition (@($staleSections | Where-Object { $_.path -eq "src/RoslynFrameworkSample/ServiceCollectionExtensions.cs" }).Count -gt 0) -Message "Stale sections should identify ServiceCollectionExtensions.cs."
        Assert-True -Condition (@($staleSections | Where-Object { $_.path -eq "src/RoslynFrameworkSample/ValuesController.cs" }).Count -gt 0) -Message "Stale sections should identify ValuesController.cs."
    }
    finally {
        if (Test-Path -LiteralPath $repoPath) {
            Remove-Item -LiteralPath $repoPath -Recurse -Force
        }
    }
}

Invoke-Test "Roslyn ChangedOnly keeps similarly named files intact" {
    $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-roslyn-ambiguous-test-" + [guid]::NewGuid().ToString("N"))
    try {
        Copy-Item -Recurse -Force (Join-Path $repoRoot "tests/fixtures/roslyn-sample") $repoPath
        Set-Content -LiteralPath (Join-Path $repoPath "src/RoslynSample/A.cs") -Value 'namespace RoslynSample; public class A { public string Ping() => "a"; }' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $repoPath "src/RoslynSample/AA.cs") -Value 'namespace RoslynSample; public class AA { public string Ping() => "aa"; }' -Encoding UTF8

        $old = Get-Location
        try {
            Set-Location $repoPath
            git init | Out-Null
            git config user.email "awf-test@example.test" | Out-Null
            git config user.name "AWF Test" | Out-Null
            git config commit.gpgsign false | Out-Null

            git add . | Out-Null
            git commit -m "Initial Roslyn sample" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Initial Roslyn test commit failed." }

            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -Indexer roslyn -RepoPath $repoPath

            Set-Content -LiteralPath (Join-Path $repoPath "src/RoslynSample/A.cs") -Value 'namespace RoslynSample; public class A { public string Ping() => "updated"; }' -Encoding UTF8
            git add src/RoslynSample/A.cs | Out-Null
            git commit -m "Edit A.cs only" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Second Roslyn test commit failed." }
        }
        finally {
            Set-Location $old
        }

        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "awf.ps1") update -ChangedOnly -Indexer roslyn -RepoPath $repoPath

        $files = @(Get-Content -LiteralPath (Join-Path $repoPath ".wi/graph/files.jsonl") -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-True -Condition (@($files | Where-Object { $_.path -eq "src/RoslynSample/AA.cs" }).Count -gt 0) -Message "ChangedOnly should keep similarly named untouched C# files in the graph."
        Assert-True -Condition (@($files | Where-Object { $_.path -eq "src/RoslynSample/A.cs" }).Count -gt 0) -Message "ChangedOnly should re-index the changed C# file."
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

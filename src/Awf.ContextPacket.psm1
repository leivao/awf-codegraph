Import-Module (Join-Path $PSScriptRoot "Awf.Util.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "Awf.CodeGraph.psm1") -Force

function New-AwfContextModel {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$TaskFile,
        [string]$Query
    )

    $toolRoot = Split-Path -Parent $PSScriptRoot
    $config = Get-AwfConfig -RootPath $toolRoot
    $graph = Join-Path $RepoPath $config.graph.workspace

    $taskText = ""
    $taskObject = $null
    if ($TaskFile) {
        $taskPath = if (Test-Path -LiteralPath $TaskFile) { $TaskFile } else { Join-Path $RepoPath $TaskFile }
        if (!(Test-Path -LiteralPath $taskPath)) {
            throw "Task file not found: $TaskFile"
        }

        $taskText = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8
        try {
            $taskObject = $taskText | ConvertFrom-Json
        }
        catch {
            $taskObject = $taskText.Trim()
        }
    }

    $changedPath = Join-Path $graph "changed-files.txt"
    $changed = if (Test-Path -LiteralPath $changedPath) {
        @(Get-Content -LiteralPath $changedPath -Encoding UTF8 | Where-Object { $_ })
    }
    else {
        @()
    }

    $files = @(Read-AwfJsonLines (Join-Path $graph "files.jsonl") | Sort-Object path)
    $symbols = @(Read-AwfJsonLines (Join-Path $graph "symbols.jsonl") | Sort-Object file, startLine, name)
    $summaries = @(Read-AwfJsonLines (Join-Path $graph "summaries.jsonl") | Sort-Object file)
    $graphStatePath = Join-Path $graph "graph-state.json"
    $graphState = if (Test-Path -LiteralPath $graphStatePath) {
        Get-Content -LiteralPath $graphStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    else {
        $null
    }

    $queryMatches = @()
    if (![string]::IsNullOrWhiteSpace($Query)) {
        $queryMatches = @(Search-AwfCodeGraph -RepoPath $RepoPath -Query $Query)
    }

    $changedNorm = @($changed | ForEach-Object { $_.Replace("\", "/") } | Sort-Object -Unique)
    $changedSymbols = @($symbols | Where-Object { $changedNorm -contains $_.file })

    $candidateFiles = @()
    $candidateFiles += $changedNorm
    $candidateFiles += @($queryMatches | ForEach-Object { $_.file })
    $candidateFiles += @($changedSymbols | ForEach-Object { $_.file })
    $seenCandidateFiles = @{}
    $candidateFiles = @($candidateFiles | Where-Object { $_ } | ForEach-Object {
        $normalized = $_.Replace("\", "/")
        if (!$seenCandidateFiles.ContainsKey($normalized)) {
            $seenCandidateFiles[$normalized] = $true
            $normalized
        }
    })

    if ($candidateFiles.Count -eq 0 -and $files.Count -gt 0) {
        $candidateFiles = @(
            $files |
                Select-Object -First $config.contextPacket.maxRecommendedFiles |
                ForEach-Object { $_.path } |
                Where-Object { $_ } |
                Sort-Object -Unique
        )
    }

    $maxSymbols = [int]$config.contextPacket.maxSymbols
    $maxSummaries = [int]$config.contextPacket.maxSummaries
    $maxRecommendedFiles = [int]$config.contextPacket.maxRecommendedFiles
    $recommendedFiles = @($candidateFiles | Select-Object -First $maxRecommendedFiles)
    $relevantSymbols = @($symbols | Where-Object { $recommendedFiles -contains $_.file } | Select-Object -First $maxSymbols)
    $safeSymbols = @($relevantSymbols | ForEach-Object {
        [pscustomobject]@{
            id = $_.id
            type = $_.type
            name = $_.name
            container = $_.container
            file = $_.file
            language = $_.language
            startLine = $_.startLine
            endLine = $_.endLine
            hash = $_.hash
        }
    })
    $relevantSummaries = @($summaries | Where-Object { $recommendedFiles -contains $_.file } | Select-Object -First $maxSummaries)

    [pscustomobject]@{
        generatedUtc = (Get-Date).ToUniversalTime().ToString("o")
        repoPath = $RepoPath
        task = $taskObject
        taskText = $taskText
        taskFormat = if ($taskObject -is [string]) { "text" } elseif ($null -ne $taskObject) { "json" } else { $null }
        query = $Query
        changedFiles = $changedNorm
        recommendedFiles = $recommendedFiles
        symbols = $safeSymbols
        summaries = $relevantSummaries
        limits = [pscustomobject]@{
            maxSymbols = $maxSymbols
            maxSummaries = $maxSummaries
            maxRecommendedFiles = $maxRecommendedFiles
        }
        graphState = $graphState
    }
}

function New-AwfContextPacket {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$TaskFile,
        [string]$Query
    )

    $toolRoot = Split-Path -Parent $PSScriptRoot
    $config = Get-AwfConfig -RootPath $toolRoot
    $runtime = Join-Path $RepoPath $config.graph.runtime
    New-AwfDirectory $runtime

    $model = New-AwfContextModel -RepoPath $RepoPath -TaskFile $TaskFile -Query $Query

    if ($TaskFile) {
        $taskPath = if (Test-Path -LiteralPath $TaskFile) { $TaskFile } else { Join-Path $RepoPath $TaskFile }
        $taskName = [System.IO.Path]::GetFileName($taskPath)
        Copy-Item -LiteralPath $taskPath -Destination (Join-Path $runtime $taskName) -Force
    }

    $md = @()
    $md += "# AI Context Packet"
    $md += ""
    $md += "Generated: $($model.generatedUtc)"
    $md += ""
    $md += "## Purpose"
    $md += "Provide compact, graph-derived repository context to an AI coding agent while minimizing token usage."
    $md += ""
    $md += "## Task"
    if ($model.taskText) {
        if ($model.taskFormat -eq "json") {
            $md += '```json'
        }
        else {
            $md += '```text'
        }
        $md += $model.taskText.Trim()
        $md += '```'
    } else {
        $md += "_No task file provided._"
    }
    $md += ""
    $md += "## Query"
    if ($model.query) {
        $md += $model.query
    }
    else {
        $md += "_No query provided._"
    }
    $md += ""
    $md += "## Changed Files"
    if ($model.changedFiles.Count -eq 0) { $md += "- No changed files detected or update was not run with ``-ChangedOnly``." } else {
        $model.changedFiles | ForEach-Object { $md += "- $_" }
    }
    $md += ""
    $md += "## Relevant Symbols"
    if ($model.symbols.Count -eq 0) { $md += "- No relevant symbols found." } else {
        $model.symbols | ForEach-Object {
            $md += "- ``$($_.type)`` **$($_.name)** in ``$($_.file)`` line $($_.startLine)"
        }
    }
    $md += ""
    $md += "## File Summaries"
    if ($model.summaries.Count -eq 0) { $md += "- No summaries found." } else {
        $model.summaries | ForEach-Object {
            $md += "- ``$($_.file)``: $($_.summary)"
        }
    }
    $md += ""
    $md += "## Recommended Files To Read First"
    if ($model.recommendedFiles.Count -eq 0) { $md += "- None." } else {
        $model.recommendedFiles | ForEach-Object { $md += "- $_" }
    }
    $md += ""
    $md += "## Agent Instructions"
    $md += "- Read only the recommended files first."
    $md += "- Ask for or retrieve additional files only when the graph context is insufficient."
    $md += "- After edits, run graph update with ``-ChangedOnly``."
    $md += "- Treat this packet as navigation context, not as a substitute for reading the exact code before editing."
    $md += "- Validate changes with build/tests."

    $out = Join-Path $runtime "context-packet.md"
    Set-Content -LiteralPath $out -Value ($md -join "`n") -Encoding UTF8

    $jsonOut = Join-Path $runtime "context-packet.json"
    $model |
        Select-Object generatedUtc, repoPath, task, query, changedFiles, recommendedFiles, symbols, summaries, limits, graphState |
        ConvertTo-Json -Depth 50 |
        Set-Content -LiteralPath $jsonOut -Encoding UTF8

    return $out
}

function Get-AwfContextPacketEvaluation {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$GraphPath,
        [Parameter(Mandatory)][string]$Seed,
        [Parameter(Mandatory)][string]$Query,
        [int]$Budget = 10
    )

    try {
        $packet = Get-AwfGraphContextPacket -GraphPath $GraphPath -Seed $Seed -Budget $Budget
    }
    catch {
        throw "Evaluation helper failed while building the graph packet: $($_.Exception.Message)"
    }

    try {
        $packetPath = New-AwfContextPacket -RepoPath $RepoPath -Query $Query
    }
    catch {
        throw "Evaluation helper failed while generating the context packet: $($_.Exception.Message)"
    }

    try {
        $packetInfo = Get-Item -LiteralPath $packetPath
    }
    catch {
        throw "Evaluation helper failed while measuring packet size at '$packetPath': $($_.Exception.Message)"
    }

    try {
        $baseline = @(Search-AwfCodeGraph -RepoPath $RepoPath -Query $Query)
    }
    catch {
        throw "Evaluation helper failed while computing the baseline query count: $($_.Exception.Message)"
    }

    $contextFileCount = 0
    $relatedTestCount = 0
    $topFiles = New-Object System.Collections.Generic.List[string]
    $topTests = New-Object System.Collections.Generic.List[string]

    foreach ($contextFile in $packet.contextFiles) {
        $contextFileCount++
        if ($topFiles.Count -lt 5 -and $contextFile.path) {
            $topFiles.Add([string]$contextFile.path)
        }
    }

    foreach ($relatedTest in $packet.relatedTests) {
        $relatedTestCount++
        if ($topTests.Count -lt 5 -and $relatedTest.path) {
            $topTests.Add([string]$relatedTest.path)
        }
    }

    [pscustomobject]@{
        seed = $Seed
        query = $Query
        baselineCount = $baseline.Count
        contextFileCount = $contextFileCount
        relatedTestCount = $relatedTestCount
        packetBytes = [int64]$packetInfo.Length
        packetPath = $packetPath
        topFiles = @($topFiles)
        topTests = @($topTests)
        packet = $packet
    }
}

Export-ModuleMember -Function @(
    "New-AwfContextModel",
    "New-AwfContextPacket"
)

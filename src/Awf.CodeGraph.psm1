Import-Module (Join-Path $PSScriptRoot "Awf.Util.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "Awf.Git.psm1") -Force

function Initialize-AwfCodeGraph {
    param([Parameter(Mandatory)][string]$RepoPath)

    $config = Get-AwfConfig -RootPath (Get-AwfToolRoot)

    New-AwfDirectory (Join-Path $RepoPath ".wi")
    New-AwfDirectory (Join-Path $RepoPath ".wi/graph")
    New-AwfDirectory (Join-Path $RepoPath ".wi/runtime")
    New-AwfDirectory (Join-Path $RepoPath ".wi/logs")

    foreach ($file in @("files.jsonl", "symbols.jsonl", "edges.jsonl", "summaries.jsonl")) {
        $path = Join-Path $RepoPath ".wi/graph/$file"
        if (!(Test-Path -LiteralPath $path)) {
            New-Item -ItemType File -Path $path -Force | Out-Null
        }
    }

    $statePath = Join-Path $RepoPath ".wi/graph/graph-state.json"
    if (!(Test-Path -LiteralPath $statePath)) {
        @{
            version = "0.1.0"
            createdUtc = (Get-Date).ToUniversalTime().ToString("o")
            lastUpdatedUtc = $null
            indexer = $config.graph.indexer
        } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -Encoding UTF8
    }
}

function Get-AwfToolRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-AwfDefaultGraphIndexer {
    $toolRoot = Get-AwfToolRoot
    $config = Get-AwfConfig -RootPath $toolRoot
    return $config.graph.indexer
}

function Get-AwfLanguage {
    param([string]$Path)
    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        ".cs" { "csharp" }
        ".ts" { "typescript" }
        ".tsx" { "typescript-react" }
        ".js" { "javascript" }
        ".jsx" { "javascript-react" }
        ".py" { "python" }
        ".json" { "json" }
        ".csproj" { "xml-project" }
        ".sln" { "dotnet-solution" }
        default { "unknown" }
    }
}

function Get-AwfFileKind {
    param([string]$Path)
    if ($Path -match "(^|[\\/])tests?[\\/]" -or $Path -match "Tests?\.(cs|ts|js|py)$" -or $Path -match "\.spec\." -or $Path -match "\.test\.") {
        return "test"
    }
    if ($Path -match "Controller\.(cs|ts|js)$") { return "api-controller" }
    if ($Path -match "Repository\.(cs|ts|js)$") { return "repository" }
    if ($Path -match "Service\.(cs|ts|js)$") { return "service" }
    if ($Path -match "Validator\.(cs|ts|js)$") { return "validator" }
    return "source"
}

function Get-AwfSymbolsFromContent {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Language
    )

    $symbols = New-Object System.Collections.Generic.List[object]
    $lines = $Content -split "`r?`n"

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $lineNumber = $i + 1

        if ($Language -eq "csharp") {
            if ($line -match "^\s*(public|private|protected|internal)?\s*(abstract|sealed|static|partial)?\s*(class|interface|record|struct|enum)\s+([A-Za-z_][A-Za-z0-9_]*)") {
                $kind = $matches[3]
                $name = $matches[4]
                $symbols.Add([pscustomobject]@{
                    id = "symbol:$RelativePath#$name"
                    type = $kind
                    name = $name
                    container = $null
                    file = $RelativePath
                    language = $Language
                    startLine = $lineNumber
                    endLine = $null
                    signature = $line.Trim()
                })
            }
            elseif ($line -match "^\s*(public|private|protected|internal)?\s*(static|virtual|override|async|sealed|new|\s)*\s*([A-Za-z0-9_<>,\[\]\?\.]+)\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(([^\)]*)\)") {
                $name = $matches[4]
                if ($name -notin @("if", "for", "while", "switch", "catch", "using", "lock")) {
                    $container = Get-AwfNearestContainer -Symbols $symbols
                    $fullName = if ($container) { "$($container.name).$name" } else { $name }
                    $symbols.Add([pscustomobject]@{
                        id = "symbol:$RelativePath#$fullName"
                        type = "method"
                        name = $name
                        container = if ($container) { $container.name } else { $null }
                        file = $RelativePath
                        language = $Language
                        startLine = $lineNumber
                        endLine = $null
                        signature = $line.Trim()
                    })
                }
            }
        }
        elseif ($Language -like "typescript*" -or $Language -like "javascript*") {
            if ($line -match "^\s*export\s+(default\s+)?(class|interface|type|enum|function)\s+([A-Za-z_][A-Za-z0-9_]*)") {
                $symbols.Add([pscustomobject]@{
                    id = "symbol:$RelativePath#$($matches[3])"
                    type = $matches[2]
                    name = $matches[3]
                    container = $null
                    file = $RelativePath
                    language = $Language
                    startLine = $lineNumber
                    endLine = $null
                    signature = $line.Trim()
                })
            }
            elseif ($line -match "^\s*(const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(async\s*)?\(?") {
                $symbols.Add([pscustomobject]@{
                    id = "symbol:$RelativePath#$($matches[2])"
                    type = "function_or_variable"
                    name = $matches[2]
                    container = $null
                    file = $RelativePath
                    language = $Language
                    startLine = $lineNumber
                    endLine = $null
                    signature = $line.Trim()
                })
            }
        }
        elseif ($Language -eq "python") {
            if ($line -match "^\s*class\s+([A-Za-z_][A-Za-z0-9_]*)") {
                $symbols.Add([pscustomobject]@{
                    id = "symbol:$RelativePath#$($matches[1])"
                    type = "class"
                    name = $matches[1]
                    container = $null
                    file = $RelativePath
                    language = $Language
                    startLine = $lineNumber
                    endLine = $null
                    signature = $line.Trim()
                })
            }
            elseif ($line -match "^\s*def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(") {
                $container = Get-AwfNearestContainer -Symbols $symbols
                $fullName = if ($container) { "$($container.name).$($matches[1])" } else { $matches[1] }
                $symbols.Add([pscustomobject]@{
                    id = "symbol:$RelativePath#$fullName"
                    type = "function"
                    name = $matches[1]
                    container = if ($container) { $container.name } else { $null }
                    file = $RelativePath
                    language = $Language
                    startLine = $lineNumber
                    endLine = $null
                    signature = $line.Trim()
                })
            }
        }
    }

    return $symbols
}

function Get-AwfNearestContainer {
    param($Symbols)
    $containers = @($Symbols | Where-Object { $_.type -in @("class", "interface", "record", "struct") })
    if ($containers.Count -eq 0) { return $null }
    return $containers[-1]
}

function Get-AwfEdgesFromContent {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)]$Symbols
    )

    $edges = New-Object System.Collections.Generic.List[object]

    foreach ($s in $Symbols) {
        $edges.Add([pscustomobject]@{
            from = "file:$RelativePath"
            to = $s.id
            type = "defines"
            confidence = "high"
            source = "powershell-regex-mvp"
        })
    }

    $importMatches = [regex]::Matches($Content, "(?m)^\s*(using|import|from|require)\s+([^;`"']+)")
    foreach ($m in $importMatches) {
        $edges.Add([pscustomobject]@{
            from = "file:$RelativePath"
            to = "import:$($m.Groups[2].Value.Trim())"
            type = "imports"
            confidence = "medium"
            source = "powershell-regex-mvp"
        })
    }

    foreach ($s in $Symbols) {
        if ($s.type -in @("method", "function", "function_or_variable")) {
            $name = [regex]::Escape($s.name)
            $callCount = ([regex]::Matches($Content, "\b$name\s*\(")).Count
            if ($callCount -gt 1) {
                $edges.Add([pscustomobject]@{
                    from = "file:$RelativePath"
                    to = $s.id
                    type = "calls_candidate"
                    confidence = "low"
                    source = "powershell-regex-mvp"
                })
            }
        }
    }

    return $edges
}

function Get-AwfFileSummary {
    param(
        [string]$RelativePath,
        [string]$Language,
        [string]$Kind,
        $Symbols
    )

    $symbolNames = @($Symbols | Select-Object -First 12 | ForEach-Object { $_.name })
    return [pscustomobject]@{
        file = $RelativePath
        language = $Language
        kind = $Kind
        summary = "Contains $Kind code. Key symbols: $($symbolNames -join ', ')."
        generatedBy = "heuristic"
        generatedUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
}

function Remove-AwfGraphEntriesForFiles {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [AllowEmptyCollection()][string[]]$RelativeFiles
    )

    $graph = Join-Path $RepoPath ".wi/graph"
    $filesSet = @{}
    foreach ($f in $RelativeFiles) { $filesSet[$f.Replace("\","/")] = $true }

    foreach ($name in @("files.jsonl", "symbols.jsonl", "summaries.jsonl")) {
        $path = Join-Path $graph $name
        $remaining = @()
        foreach ($item in Read-AwfJsonLines $path) {
            $file = if ($item.file) { $item.file } elseif ($item.path) { $item.path } else { $null }
            if (!$file -or !$filesSet.ContainsKey($file.Replace("\","/"))) {
                $remaining += ($item | ConvertTo-Json -Compress -Depth 20)
            }
        }
        Set-Content -LiteralPath $path -Value $remaining -Encoding UTF8
    }

    $edgesPath = Join-Path $graph "edges.jsonl"
    $remainingEdges = @()
    foreach ($edge in Read-AwfJsonLines $edgesPath) {
        $remove = $false
        foreach ($f in $filesSet.Keys) {
            $escaped = [regex]::Escape($f)
            if (($edge.from -match "^file:$escaped$") -or ($edge.to -match "^symbol:$escaped#")) {
                $remove = $true
                break
            }
        }
        if (!$remove) {
            $remainingEdges += ($edge | ConvertTo-Json -Compress -Depth 20)
        }
    }
    Set-Content -LiteralPath $edgesPath -Value $remainingEdges -Encoding UTF8
}

function Clear-AwfGraphEntries {
    param([Parameter(Mandatory)][string]$RepoPath)

    $graph = Join-Path $RepoPath ".wi/graph"
    foreach ($name in @("files.jsonl", "symbols.jsonl", "edges.jsonl", "summaries.jsonl")) {
        Set-Content -LiteralPath (Join-Path $graph $name) -Value @() -Encoding UTF8
    }
}

function Get-AwfPowerShellGraphRecords {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [AllowEmptyCollection()][string[]]$RelativeFiles,
        [switch]$VerboseOutput
    )

    $records = [ordered]@{
        files = New-Object System.Collections.Generic.List[object]
        symbols = New-Object System.Collections.Generic.List[object]
        edges = New-Object System.Collections.Generic.List[object]
        summaries = New-Object System.Collections.Generic.List[object]
        indexedFiles = New-Object System.Collections.Generic.List[string]
    }

    foreach ($relative in @($RelativeFiles | Where-Object { $_ } | Sort-Object -Unique)) {
        $full = Join-Path $RepoPath $relative
        if (!(Test-Path -LiteralPath $full)) { continue }

        $language = Get-AwfLanguage -Path $relative
        $kind = Get-AwfFileKind -Path $relative
        $content = Get-Content -LiteralPath $full -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($null -eq $content) { $content = "" }

        $hash = Get-AwfSha256 -Path $full
        $lineCount = ($content -split "`r?`n").Count
        $relativeNormalized = $relative.Replace("\","/")
        $symbols = @(Get-AwfSymbolsFromContent -RelativePath $relativeNormalized -Content $content -Language $language)
        $edges = @(Get-AwfEdgesFromContent -RelativePath $relativeNormalized -Content $content -Symbols $symbols)
        $summary = Get-AwfFileSummary -RelativePath $relativeNormalized -Language $language -Kind $kind -Symbols $symbols

        $records.files.Add([pscustomobject]@{
            id = "file:$relativeNormalized"
            path = $relativeNormalized
            language = $language
            kind = $kind
            hash = $hash
            lineCount = $lineCount
            source = "powershell-regex-mvp"
            confidence = "medium"
            indexedUtc = (Get-Date).ToUniversalTime().ToString("o")
        })
        $records.indexedFiles.Add($relativeNormalized)

        foreach ($s in $symbols) {
            $s | Add-Member -NotePropertyName hash -NotePropertyValue $hash -Force
            $s | Add-Member -NotePropertyName source -NotePropertyValue "powershell-regex-mvp" -Force
            $s | Add-Member -NotePropertyName confidence -NotePropertyValue "medium" -Force
            $s | Add-Member -NotePropertyName indexedUtc -NotePropertyValue (Get-Date).ToUniversalTime().ToString("o") -Force
            $records.symbols.Add($s)
        }

        foreach ($e in $edges) {
            $records.edges.Add($e)
        }

        $summary | Add-Member -NotePropertyName source -NotePropertyValue "powershell-regex-mvp" -Force
        $summary | Add-Member -NotePropertyName confidence -NotePropertyValue "medium" -Force
        $summary | Add-Member -NotePropertyName indexedUtc -NotePropertyValue (Get-Date).ToUniversalTime().ToString("o") -Force
        $records.summaries.Add($summary)

        if ($VerboseOutput) {
            Write-AwfInfo "Indexed $relative (PowerShell path: $($symbols.Count) symbols, $($edges.Count) edges)"
        }
    }

    return $records
}

function Get-AwfGraphData {
    param([Parameter(Mandatory)][string]$GraphPath)

    $filesPath = Join-Path $GraphPath "files.jsonl"
    $symbolsPath = Join-Path $GraphPath "symbols.jsonl"
    $edgesPath = Join-Path $GraphPath "edges.jsonl"
    $summariesPath = Join-Path $GraphPath "summaries.jsonl"

    foreach ($path in @($filesPath, $symbolsPath, $edgesPath, $summariesPath)) {
        if (!(Test-Path -LiteralPath $path)) {
            throw "Graph retrieval requires files.jsonl, symbols.jsonl, edges.jsonl, and summaries.jsonl in '$GraphPath'."
        }
    }

    $files = @(Read-AwfJsonLines $filesPath)
    $symbols = @(Read-AwfJsonLines $symbolsPath)
    $edges = @(Read-AwfJsonLines $edgesPath)
    $summaries = @(Read-AwfJsonLines $summariesPath)

    $filesById = @{}
    $filesByPath = @{}
    foreach ($file in $files) {
        if ($file.id) { $filesById[[string]$file.id] = $file }
        if ($file.path) { $filesByPath[[string]$file.path] = $file }
    }

    $symbolsById = @{}
    $symbolsByFile = @{}
    foreach ($symbol in $symbols) {
        if ($symbol.id) { $symbolsById[[string]$symbol.id] = $symbol }
        if ($symbol.file) {
            $fileKey = [string]$symbol.file
            if (!$symbolsByFile.ContainsKey($fileKey)) {
                $symbolsByFile[$fileKey] = New-Object System.Collections.Generic.List[object]
            }
            $symbolsByFile[$fileKey].Add($symbol)
        }
    }

    $edgesByFrom = @{}
    $edgesByTo = @{}
    foreach ($edge in $edges) {
        if ($edge.from) {
            $fromKey = [string]$edge.from
            if (!$edgesByFrom.ContainsKey($fromKey)) {
                $edgesByFrom[$fromKey] = New-Object System.Collections.Generic.List[object]
            }
            $edgesByFrom[$fromKey].Add($edge)
        }

        if ($edge.to) {
            $toKey = [string]$edge.to
            if (!$edgesByTo.ContainsKey($toKey)) {
                $edgesByTo[$toKey] = New-Object System.Collections.Generic.List[object]
            }
            $edgesByTo[$toKey].Add($edge)
        }
    }

    $summariesByFile = @{}
    foreach ($summary in $summaries) {
        if ($summary.file) {
            $summariesByFile[[string]$summary.file] = $summary
        }
    }

    [pscustomobject]@{
        GraphPath = $GraphPath
        Files = $files
        Symbols = $symbols
        Edges = $edges
        Summaries = $summaries
        FilesById = $filesById
        FilesByPath = $filesByPath
        SymbolsById = $symbolsById
        SymbolsByFile = $symbolsByFile
        EdgesByFrom = $edgesByFrom
        EdgesByTo = $edgesByTo
        SummariesByFile = $summariesByFile
    }
}

function Get-AwfGraphSeedInfo {
    param(
        [Parameter(Mandatory)]$GraphData,
        [Parameter(Mandatory)][string]$Seed
    )

    $seedPath = $Seed.Replace("\","/")
    $seedFile = $null
    $seedSymbol = $null

    if ($GraphData.FilesByPath.ContainsKey($seedPath)) {
        $seedFile = $GraphData.FilesByPath[$seedPath]
    }

    if (!$seedFile -and $GraphData.FilesById.ContainsKey($Seed)) {
        $seedFile = $GraphData.FilesById[$Seed]
        if ($seedFile.path) {
            $seedPath = [string]$seedFile.path
        }
    }

    if ($GraphData.SymbolsById.ContainsKey($Seed)) {
        $seedSymbol = $GraphData.SymbolsById[$Seed]
        if ($seedSymbol.file -and !$seedFile -and $GraphData.FilesByPath.ContainsKey([string]$seedSymbol.file)) {
            $seedFile = $GraphData.FilesByPath[[string]$seedSymbol.file]
            $seedPath = [string]$seedFile.path
        }
    }

    if (!$seedFile -and !$seedSymbol) {
        $seedSymbol = $GraphData.Symbols | Where-Object { $_.id -eq $Seed -or $_.name -eq $Seed } | Select-Object -First 1
        if ($seedSymbol -and $seedSymbol.file -and $GraphData.FilesByPath.ContainsKey([string]$seedSymbol.file)) {
            $seedFile = $GraphData.FilesByPath[[string]$seedSymbol.file]
            $seedPath = [string]$seedFile.path
        }
    }

    [pscustomobject]@{
        Seed = $Seed
        SeedPath = $seedPath
        SeedFile = $seedFile
        SeedSymbol = $seedSymbol
        SeedDirectory = if ($seedPath) { [System.IO.Path]::GetDirectoryName($seedPath).Replace("\","/") } else { $null }
        SeedNamespace = if ($seedSymbol -and $seedSymbol.container) { [string]$seedSymbol.container } else { $null }
    }
}

function Add-AwfGraphCandidate {
    param(
        [Parameter(Mandatory)]$Candidates,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$Score,
        [Parameter(Mandatory)][string]$Reason,
        [string]$SymbolId,
        [string]$Kind
    )

    $existing = if ($Candidates.ContainsKey($Key)) { $Candidates[$Key] } else { $null }
    if ($existing -and $existing.score -ge $Score) {
        return
    }

    $Candidates[$Key] = [pscustomobject]@{
        key = $Key
        path = $Path
        symbolId = $SymbolId
        kind = $Kind
        score = $Score
        reason = $Reason
    }
}

function Get-AwfGraphBlastRadius {
    param(
        [Parameter(Mandatory)][string]$GraphPath,
        [Parameter(Mandatory)][string]$Seed
    )

    $graph = Get-AwfGraphData -GraphPath $GraphPath
    $seedInfo = Get-AwfGraphSeedInfo -GraphData $graph -Seed $Seed
    if (!$seedInfo.SeedFile) {
        return @()
    }

    $candidates = @{}
    $seedPath = $seedInfo.SeedPath
    $seedDirectory = $seedInfo.SeedDirectory
    $seedNamespace = $seedInfo.SeedNamespace

    Add-AwfGraphCandidate -Candidates $candidates -Key $seedPath -Path $seedPath -Score 1000 -Reason "seed file"

    $seedSymbols = @($graph.SymbolsByFile[$seedPath] | ForEach-Object { $_ })
    foreach ($symbol in $seedSymbols) {
        Add-AwfGraphCandidate -Candidates $candidates -Key $symbol.id -Path $seedPath -Score 990 -Reason "symbol defined in seed file" -SymbolId $symbol.id -Kind $symbol.type
    }

    foreach ($edge in @($graph.EdgesByFrom["file:$seedPath"] | ForEach-Object { $_ })) {
        if ($edge.to -and $graph.SymbolsById.ContainsKey([string]$edge.to)) {
            $targetSymbol = $graph.SymbolsById[[string]$edge.to]
            $targetPath = [string]$targetSymbol.file
            if ($targetPath) {
                Add-AwfGraphCandidate -Candidates $candidates -Key $targetPath -Path $targetPath -Score 850 -Reason "direct dependency from seed file" -SymbolId $targetSymbol.id -Kind $targetSymbol.type
            }
        }
    }

    foreach ($file in $graph.Files) {
        if (!$file.path -or $file.path -eq $seedPath) { continue }
        $filePath = [string]$file.path
        $score = 0
        $reason = $null

        if ($seedDirectory -and ([System.IO.Path]::GetDirectoryName($filePath).Replace("\","/") -eq $seedDirectory)) {
            $score = 700
            $reason = "same project directory"
        }
        elseif ($seedNamespace -and $graph.SummariesByFile.ContainsKey($filePath) -and $graph.SummariesByFile[$filePath].summary -match [regex]::Escape($seedNamespace)) {
            $score = 650
            $reason = "same namespace"
        }
        elseif ($graph.SummariesByFile.ContainsKey($filePath) -and $graph.SummariesByFile[$filePath].kind -eq "test") {
            $score = 400
            $reason = "test file"
        }

        if ($score -gt 0) {
            Add-AwfGraphCandidate -Candidates $candidates -Key $filePath -Path $filePath -Score $score -Reason $reason
        }
    }

    return @(
        $candidates.Values |
            Sort-Object @{Expression = "score"; Descending = $true}, @{Expression = "path"; Descending = $false}, @{Expression = "symbolId"; Descending = $false}
    )
}

function Get-AwfGraphRelatedTests {
    param(
        [Parameter(Mandatory)][string]$GraphPath,
        [Parameter(Mandatory)][string]$Seed
    )

    $graph = Get-AwfGraphData -GraphPath $GraphPath
    $seedInfo = Get-AwfGraphSeedInfo -GraphData $graph -Seed $Seed
    if (!$seedInfo.SeedFile) {
        return @()
    }

    $seedPath = $seedInfo.SeedPath
    $seedSymbolIds = @($graph.SymbolsByFile[$seedPath] | ForEach-Object { $_.id })
    $candidates = @{}

    foreach ($file in $graph.Files) {
        if (!$file.path) { continue }
        $filePath = [string]$file.path
        $summary = if ($graph.SummariesByFile.ContainsKey($filePath)) { $graph.SummariesByFile[$filePath] } else { $null }
        $score = 0
        $reason = $null

        if (($file.kind -eq "test") -or ($summary -and $summary.kind -eq "test")) {
            $score = 600
            $reason = "classified as test"
        }
        elseif ($filePath -match "(^|[\\/])tests?([\\/]|$)" -or $filePath -match "Tests?\.(cs|csproj)$") {
            $score = 500
            $reason = "test naming or path"
        }

        if ($score -le 0) {
            continue
        }

        foreach ($edge in @($graph.Edges | Where-Object {
            $_.from -like "file:$filePath" -and $_.to -in $seedSymbolIds
        })) {
            $score = [Math]::Max($score, 800)
            $reason = "direct reference to seed symbol"
        }

        if ($filePath -match "(^|[\\/])tests?([\\/]|$)") {
            $score += 25
        }

        Add-AwfGraphCandidate -Candidates $candidates -Key $filePath -Path $filePath -Score $score -Reason $reason
    }

    return @(
        $candidates.Values |
            Sort-Object @{Expression = "score"; Descending = $true}, @{Expression = "path"; Descending = $false}, @{Expression = "symbolId"; Descending = $false}
    )
}

function Get-AwfGraphContextPacket {
    param(
        [Parameter(Mandatory)][string]$GraphPath,
        [Parameter(Mandatory)][string]$Seed,
        [int]$Budget = 10
    )

    $blastRadius = @(Get-AwfGraphBlastRadius -GraphPath $GraphPath -Seed $Seed)
    $relatedTests = @(Get-AwfGraphRelatedTests -GraphPath $GraphPath -Seed $Seed)

    $contextFiles = New-Object System.Collections.Generic.List[object]
    $contextSymbols = New-Object System.Collections.Generic.List[object]
    $seenFiles = @{}
    $seenSymbols = @{}

    foreach ($candidate in @($blastRadius + $relatedTests)) {
        if ($contextFiles.Count -ge $Budget) { break }
        if (!$candidate.path -or $seenFiles.ContainsKey($candidate.path)) { continue }

        $contextFiles.Add([pscustomobject]@{
            path = $candidate.path
            score = $candidate.score
            reason = $candidate.reason
            kind = $candidate.kind
            symbolId = $candidate.symbolId
        })
        $seenFiles[$candidate.path] = $true

        if ($candidate.symbolId -and !$seenSymbols.ContainsKey($candidate.symbolId)) {
            $contextSymbols.Add([pscustomobject]@{
                id = $candidate.symbolId
                path = $candidate.path
                score = $candidate.score
                reason = $candidate.reason
            })
            $seenSymbols[$candidate.symbolId] = $true
        }
    }

    [pscustomobject]@{
        primary = $Seed.Replace("\","/")
        blastRadius = $blastRadius
        relatedTests = $relatedTests
        contextFiles = $contextFiles
        contextSymbols = $contextSymbols
    }
}

function Get-AwfRoslynSolutionPaths {
    param([Parameter(Mandatory)][string]$RepoPath)

    return @(
        Get-ChildItem -LiteralPath $RepoPath -Recurse -Filter *.sln -File |
            Where-Object { $_.FullName -notmatch '(^|[\\/])(\.git|\.wi|node_modules|bin|obj|dist|build)([\\/]|$)' } |
            ForEach-Object { $_.FullName } |
            Sort-Object -Unique
    )
}

function Get-AwfRoslynProjectPaths {
    param([Parameter(Mandatory)][string]$RepoPath)

    return @(
        Get-ChildItem -LiteralPath $RepoPath -Recurse -Filter *.csproj -File |
            Where-Object { $_.FullName -notmatch '(^|[\\/])(\.git|\.wi|node_modules|bin|obj|dist|build)([\\/]|$)' } |
            ForEach-Object { $_.FullName } |
            Sort-Object -Unique
    )
}

function Get-AwfRoslynSupplementalFiles {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [AllowEmptyCollection()][string[]]$BaseRelativeFiles,
        [AllowEmptyCollection()][string[]]$ExcludeDirectories,
        [switch]$ChangedOnly
    )

    $baseSet = @{}
    foreach ($file in @($BaseRelativeFiles | Where-Object { $_ })) {
        $baseSet[$file.Replace("\","/")] = $true
    }

    $excludeNames = @($ExcludeDirectories | Where-Object { ![string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [regex]::Escape($_) })
    $excludePattern = if ($excludeNames.Count -gt 0) {
        "(^|[\\/])(" + ($excludeNames -join "|") + ")([\\/]|$)"
    }
    else {
        $null
    }

    if ($ChangedOnly) {
        $old = Get-Location
        try {
            Set-Location $RepoPath
            $files = @()
            $oldErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = "Continue"
                $files += @(git diff --name-only HEAD 2>$null)
                $files += @(git diff --name-only --cached 2>$null)
                $files += @(git ls-files --others --exclude-standard 2>$null)
            }
            finally {
                $ErrorActionPreference = $oldErrorActionPreference
            }

            return @(
                $files |
                    Where-Object { $_ } |
                    ForEach-Object { $_.Replace("\","/") } |
                    Where-Object { !$baseSet.ContainsKey($_) } |
                    Where-Object { [System.IO.Path]::GetExtension($_).ToLowerInvariant() -in @(".txt", ".md") } |
                    Where-Object { !$excludePattern -or ($_ -notmatch $excludePattern) } |
                    Sort-Object -Unique
            )
        }
        finally {
            Set-Location $old
        }
    }

    return @(
        Get-ChildItem -LiteralPath $RepoPath -Recurse -File |
            Where-Object { $_.Extension.ToLowerInvariant() -in @(".txt", ".md") } |
            ForEach-Object { ConvertTo-AwfRelativePath -BasePath $RepoPath -FullPath $_.FullName } |
            ForEach-Object { $_.Replace("\","/") } |
            Where-Object { !$baseSet.ContainsKey($_) } |
            Where-Object { !$excludePattern -or ($_ -notmatch $excludePattern) } |
            Sort-Object -Unique
    )
}

function Get-AwfRoslynIncrementalScope {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [AllowEmptyCollection()][string[]]$RelativeFiles,
        [switch]$ChangedOnly
    )

    $normalized = @($RelativeFiles | Where-Object { $_ } | ForEach-Object { $_.Replace("\","/") } | Sort-Object -Unique)
    $csharpFiles = @($normalized | Where-Object { [System.IO.Path]::GetExtension($_).ToLowerInvariant() -eq ".cs" })
    $nonCSharpFiles = @($normalized | Where-Object { [System.IO.Path]::GetExtension($_).ToLowerInvariant() -ne ".cs" })

    $projectPaths = @(Get-AwfRoslynProjectPaths -RepoPath $RepoPath)
    $safe = $true
    $staleSections = @()
    if ($ChangedOnly -and ($csharpFiles.Count -gt 1 -or $projectPaths.Count -gt 1)) {
        $safe = $false
        $staleSections = @(
            foreach ($file in $csharpFiles) {
                [pscustomobject]@{
                    path = $file
                    reason = "Roslyn partial refresh widened across multiple changed C# files."
                    staleUtc = (Get-Date).ToUniversalTime().ToString("o")
                }
            }
        )
    }
    elseif ($ChangedOnly -and $csharpFiles.Count -eq 0) {
        $safe = $false
        $staleSections = @(
            [pscustomobject]@{
                path = "roslyn-csharp"
                reason = "Roslyn partial refresh deferred because no C# files changed."
                staleUtc = (Get-Date).ToUniversalTime().ToString("o")
            }
        )
    }

    [pscustomobject]@{
        changedOnly = [bool]$ChangedOnly
        safe = $safe
        relativeFiles = $normalized
        csharpFiles = $csharpFiles
        nonCSharpFiles = $nonCSharpFiles
        projectPaths = $projectPaths
        staleSections = $staleSections
    }
}

function Get-AwfRoslynGraphRecords {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [AllowEmptyCollection()][string[]]$CSharpFiles,
        [switch]$ChangedOnly,
        [switch]$VerboseOutput
    )

    $records = [ordered]@{
        files = New-Object System.Collections.Generic.List[object]
        symbols = New-Object System.Collections.Generic.List[object]
        edges = New-Object System.Collections.Generic.List[object]
        summaries = New-Object System.Collections.Generic.List[object]
        indexedFiles = New-Object System.Collections.Generic.List[string]
    }

    $csharpFiles = @($CSharpFiles | Where-Object { $_ } | ForEach-Object { $_.Replace("\","/") } | Sort-Object -Unique)
    if ($csharpFiles.Count -eq 0) {
        return $records
    }

    $solutionPaths = @(Get-AwfRoslynSolutionPaths -RepoPath $RepoPath)
    $projectPaths = @()
    $runTargets = @()
    if ($solutionPaths.Count -gt 0) {
        $runTargets = @($solutionPaths | ForEach-Object {
            [pscustomobject]@{
                kind = "solution"
                path = $_
            }
        })
    }
    else {
        $projectPaths = @(Get-AwfRoslynProjectPaths -RepoPath $RepoPath)
        if ($projectPaths.Count -eq 0) {
            throw "Roslyn indexing requires a .sln or .csproj file in '$RepoPath'. Add or restore a project file, or use -Indexer powershell."
        }

        $runTargets = @($projectPaths | ForEach-Object {
            [pscustomobject]@{
                kind = "project"
                path = $_
            }
        })
    }

    $csharpSet = @{}
    foreach ($file in $csharpFiles) {
        $csharpSet[$file] = $true
    }

    $seenFiles = @{}
    $seenSymbols = @{}
    $seenEdges = @{}
    $seenSummaries = @{}

    foreach ($target in $runTargets) {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("awf-roslyn-output-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $projectPath = Join-Path (Get-AwfToolRoot) "tools/Awf.CodeGraph.RoslynIndexer"

            if ($VerboseOutput) {
                Write-AwfInfo "Running Roslyn indexer for $(Split-Path -Leaf $target.path)"
            }

            if ($target.kind -eq "solution") {
                & dotnet run --project $projectPath -- --repo $RepoPath --solution $target.path --output $tempRoot
            }
            else {
                & dotnet run --project $projectPath -- --repo $RepoPath --project $target.path --output $tempRoot
            }
            if ($LASTEXITCODE -ne 0) {
                throw "Roslyn indexer failed for $($target.kind) '$($target.path)'."
            }

            foreach ($fileRecord in @(Read-AwfJsonLines (Join-Path $tempRoot "files.jsonl"))) {
                $path = if ($fileRecord.path) { [string]$fileRecord.path } else { $null }
                if (!$path -or ($ChangedOnly -and !$csharpSet.ContainsKey($path)) -or !$csharpSet.ContainsKey($path) -or $seenFiles.ContainsKey($path)) {
                    continue
                }

                $records.files.Add($fileRecord)
                $records.indexedFiles.Add($path)
                $seenFiles[$path] = $true
            }

            foreach ($symbolRecord in @(Read-AwfJsonLines (Join-Path $tempRoot "symbols.jsonl"))) {
                $file = if ($symbolRecord.file) { [string]$symbolRecord.file } else { $null }
                $id = if ($symbolRecord.id) { [string]$symbolRecord.id } else { $null }
                if (!$file -or !$id -or !$csharpSet.ContainsKey($file) -or $seenSymbols.ContainsKey($id)) {
                    continue
                }

                $records.symbols.Add($symbolRecord)
                $seenSymbols[$id] = $true
            }

            foreach ($edgeRecord in @(Read-AwfJsonLines (Join-Path $tempRoot "edges.jsonl"))) {
                $edgeKey = "$($edgeRecord.from)|$($edgeRecord.to)|$($edgeRecord.type)"
                $matchesCSharp = $false
                foreach ($file in $csharpSet.Keys) {
                    if (($edgeRecord.from -like "*$file*") -or ($edgeRecord.to -like "*$file*")) {
                        $matchesCSharp = $true
                        break
                    }
                }

                if (!$matchesCSharp -or $seenEdges.ContainsKey($edgeKey)) {
                    continue
                }

                $records.edges.Add($edgeRecord)
                $seenEdges[$edgeKey] = $true
            }

            foreach ($summaryRecord in @(Read-AwfJsonLines (Join-Path $tempRoot "summaries.jsonl"))) {
                $file = if ($summaryRecord.file) { [string]$summaryRecord.file } else { $null }
                if (!$file -or !$csharpSet.ContainsKey($file) -or $seenSummaries.ContainsKey($file)) {
                    continue
                }

                $records.summaries.Add($summaryRecord)
                $seenSummaries[$file] = $true
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    return $records
}

function Write-AwfGraphRecords {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)]$Records
    )

    $graph = Join-Path $RepoPath ".wi/graph"
    foreach ($record in $Records.files) {
        Add-AwfJsonLine -Path (Join-Path $graph "files.jsonl") -Object $record
    }
    foreach ($record in $Records.symbols) {
        Add-AwfJsonLine -Path (Join-Path $graph "symbols.jsonl") -Object $record
    }
    foreach ($record in $Records.edges) {
        Add-AwfJsonLine -Path (Join-Path $graph "edges.jsonl") -Object $record
    }
    foreach ($record in $Records.summaries) {
        Add-AwfJsonLine -Path (Join-Path $graph "summaries.jsonl") -Object $record
    }
}

function Update-AwfCodeGraph {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [ValidateSet("powershell", "roslyn")][string]$Indexer,
        [switch]$ChangedOnly,
        [switch]$VerboseOutput
    )

    $graph = Join-Path $RepoPath ".wi/graph"
    $config = Get-AwfConfig -RootPath (Get-AwfToolRoot)
    $extensions = @($config.graph.extensions)
    $excludeDirectories = @($config.graph.excludeDirectories)
    $indexer = if ([string]::IsNullOrWhiteSpace($Indexer)) { Get-AwfDefaultGraphIndexer } else { $Indexer }
    $fileDiscovery = if ($ChangedOnly) { "git" } else { "unknown" }

    if ($ChangedOnly) {
        $relativeFiles = @(Get-AwfChangedFiles -RepoPath $RepoPath -Extensions $extensions -ExcludeDirectories $excludeDirectories)
        if ($indexer -eq "roslyn") {
            $relativeFiles += @(Get-AwfRoslynSupplementalFiles -RepoPath $RepoPath -BaseRelativeFiles $relativeFiles -ExcludeDirectories $excludeDirectories -ChangedOnly)
            $relativeFiles = @($relativeFiles | Where-Object { $_ } | Sort-Object -Unique)
        }
        $changedPath = Join-Path $graph "changed-files.txt"
        Set-Content -LiteralPath $changedPath -Value $relativeFiles -Encoding UTF8
        if ($relativeFiles.Count -eq 0) {
            @{
                version = "0.1.0"
                lastUpdatedUtc = (Get-Date).ToUniversalTime().ToString("o")
                changedOnly = [bool]$ChangedOnly
                indexedFileCount = $relativeFiles.Count
                indexer = $indexer
                fileDiscovery = $fileDiscovery
                staleSections = @()
            } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $graph "graph-state.json") -Encoding UTF8
            Write-AwfWarn "No changed source files detected."
            return
        }
    }
    else {
        $discovery = Get-AwfRepoFileDiscovery -RepoPath $RepoPath -Extensions $extensions -ExcludeDirectories $excludeDirectories
        $relativeFiles = @($discovery.files)
        if ($indexer -eq "roslyn") {
            $relativeFiles += @(Get-AwfRoslynSupplementalFiles -RepoPath $RepoPath -BaseRelativeFiles $relativeFiles -ExcludeDirectories $excludeDirectories)
            $relativeFiles = @($relativeFiles | Where-Object { $_ } | Sort-Object -Unique)
        }
        $fileDiscovery = $discovery.method
        Set-Content -LiteralPath (Join-Path $graph "changed-files.txt") -Value @() -Encoding UTF8
    }

    $records = [ordered]@{
        files = New-Object System.Collections.Generic.List[object]
        symbols = New-Object System.Collections.Generic.List[object]
        edges = New-Object System.Collections.Generic.List[object]
        summaries = New-Object System.Collections.Generic.List[object]
        indexedFiles = New-Object System.Collections.Generic.List[string]
    }
    $staleSections = @()

    if ($indexer -eq "roslyn") {
        $incrementalScope = Get-AwfRoslynIncrementalScope -RepoPath $RepoPath -RelativeFiles $relativeFiles -ChangedOnly:$ChangedOnly
        $csharpFiles = @($incrementalScope.csharpFiles)
        $nonCSharpFiles = @($incrementalScope.nonCSharpFiles)
        $staleSections = @($incrementalScope.staleSections)

        $powershellRecords = Get-AwfPowerShellGraphRecords -RepoPath $RepoPath -RelativeFiles $nonCSharpFiles -VerboseOutput:$VerboseOutput
        $roslynRecords = Get-AwfRoslynGraphRecords -RepoPath $RepoPath -CSharpFiles $csharpFiles -ChangedOnly:$ChangedOnly -VerboseOutput:$VerboseOutput

        foreach ($name in @("files", "symbols", "edges", "summaries", "indexedFiles")) {
            foreach ($item in $powershellRecords.$name) {
                $records.$name.Add($item)
            }
            foreach ($item in $roslynRecords.$name) {
                $records.$name.Add($item)
            }
        }
    }
    else {
        $powershellRecords = Get-AwfPowerShellGraphRecords -RepoPath $RepoPath -RelativeFiles $relativeFiles -VerboseOutput:$VerboseOutput
        foreach ($name in @("files", "symbols", "edges", "summaries", "indexedFiles")) {
            foreach ($item in $powershellRecords.$name) {
                $records.$name.Add($item)
            }
        }
    }

    if ($ChangedOnly) {
        Remove-AwfGraphEntriesForFiles -RepoPath $RepoPath -RelativeFiles $relativeFiles
    }
    else {
        Clear-AwfGraphEntries -RepoPath $RepoPath
    }

    Write-AwfGraphRecords -RepoPath $RepoPath -Records $records

    @{
        version = "0.1.0"
        lastUpdatedUtc = (Get-Date).ToUniversalTime().ToString("o")
        changedOnly = [bool]$ChangedOnly
        indexedFileCount = @($records.indexedFiles | Sort-Object -Unique).Count
        indexer = $indexer
        fileDiscovery = $fileDiscovery
        staleSections = $staleSections
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $graph "graph-state.json") -Encoding UTF8
}

function Search-AwfCodeGraph {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Query
    )

    $graph = Join-Path $RepoPath ".wi/graph"
    $files = @(Read-AwfJsonLines (Join-Path $graph "files.jsonl"))
    $symbols = @(Read-AwfJsonLines (Join-Path $graph "symbols.jsonl"))
    $summaries = @(Read-AwfJsonLines (Join-Path $graph "summaries.jsonl"))

    $q = [regex]::Escape($Query)

    $fileMatches = @($files | Where-Object { $_.path -match $q -or $_.kind -match $q -or $_.language -match $q } | ForEach-Object {
        [pscustomobject]@{ type="file"; name=$_.path; file=$_.path; detail="$($_.kind) / $($_.language)" }
    })

    $symbolMatches = @($symbols | Where-Object { $_.name -match $q -or $_.container -match $q -or $_.signature -match $q } | ForEach-Object {
        [pscustomobject]@{ type=$_.type; name=$_.name; file=$_.file; detail=$_.signature }
    })

    $summaryMatches = @($summaries | Where-Object { $_.summary -match $q } | ForEach-Object {
        [pscustomobject]@{ type="summary"; name=$_.file; file=$_.file; detail=$_.summary }
    })

    return @($symbolMatches + $fileMatches + $summaryMatches) | Select-Object -First 50
}

function New-AwfImpactReport {
    param([Parameter(Mandatory)][string]$RepoPath)

    $graph = Join-Path $RepoPath ".wi/graph"
    $changedPath = Join-Path $graph "changed-files.txt"

    $changed = @()
    if (Test-Path -LiteralPath $changedPath) {
        $changed = @(Get-Content -LiteralPath $changedPath -Encoding UTF8 | Where-Object { $_ })
    }
    if ($changed.Count -eq 0) {
        $changed = @(Get-AwfChangedFiles -RepoPath $RepoPath)
    }

    $symbols = @(Read-AwfJsonLines (Join-Path $graph "symbols.jsonl"))
    $summaries = @(Read-AwfJsonLines (Join-Path $graph "summaries.jsonl"))

    $changedNorm = @($changed | ForEach-Object { $_.Replace("\","/") })

    $changedSymbols = @($symbols | Where-Object { $changedNorm -contains $_.file })
    $relatedTests = @($summaries | Where-Object {
        $_.kind -eq "test" -and (
            ($changedSymbols | ForEach-Object { $_.name }) | Where-Object { $_ -and $_.Length -gt 3 -and $($_.file + " " + $_.summary) -match [regex]::Escape($_) }
        )
    })

    $md = @()
    $md += "# AWF Code Graph Impact Report"
    $md += ""
    $md += "Generated: $((Get-Date).ToUniversalTime().ToString("o"))"
    $md += ""
    $md += "## Changed Files"
    if ($changedNorm.Count -eq 0) { $md += "- No changed files detected." } else { $changedNorm | ForEach-Object { $md += "- $_" } }
    $md += ""
    $md += "## Changed Symbols"
    if ($changedSymbols.Count -eq 0) { $md += "- No changed symbols detected." } else {
        $changedSymbols | ForEach-Object { $md += "- `$($_.type)` **$($_.name)** in `$($_.file)` line $($_.startLine)" }
    }
    $md += ""
    $md += "## Recommended Files To Read"
    $recommend = @($changedNorm + ($changedSymbols | ForEach-Object { $_.file })) | Sort-Object -Unique
    if ($recommend.Count -eq 0) { $md += "- None." } else { $recommend | ForEach-Object { $md += "- $_" } }
    $md += ""
    $md += "## Review Guidance"
    $md += "- Validate the changed files against the task acceptance criteria."
    $md += "- Verify nearby tests or add tests if no direct tests are present."
    $md += '- Re-run `awf-graph update -ChangedOnly` after agent edits.'
    $md += "- Treat regex-derived `calls_candidate` edges as advisory, not authoritative."

    $out = Join-Path $graph "impact.md"
    Set-Content -LiteralPath $out -Value ($md -join "`n") -Encoding UTF8
    return $out
}

function Get-AwfCodeGraphStatus {
    param([Parameter(Mandatory)][string]$RepoPath)

    $graph = Join-Path $RepoPath ".wi/graph"
    $files = @(Read-AwfJsonLines (Join-Path $graph "files.jsonl"))
    $symbols = @(Read-AwfJsonLines (Join-Path $graph "symbols.jsonl"))
    $edges = @(Read-AwfJsonLines (Join-Path $graph "edges.jsonl"))
    $statePath = Join-Path $graph "graph-state.json"
    $state = if (Test-Path $statePath) { Get-Content $statePath -Raw | ConvertFrom-Json } else { $null }

    [pscustomobject]@{
        RepoPath = $RepoPath
        GraphPath = $graph
        Files = $files.Count
        Symbols = $symbols.Count
        Edges = $edges.Count
        LastUpdatedUtc = if ($state) { $state.lastUpdatedUtc } else { $null }
        Indexer = if ($state) { $state.indexer } else { $null }
    }
}

Export-ModuleMember -Function @(
    "Initialize-AwfCodeGraph",
    "Update-AwfCodeGraph",
    "Search-AwfCodeGraph",
    "New-AwfImpactReport",
    "Get-AwfCodeGraphStatus",
    "Get-AwfGraphBlastRadius",
    "Get-AwfGraphRelatedTests",
    "Get-AwfGraphContextPacket"
)

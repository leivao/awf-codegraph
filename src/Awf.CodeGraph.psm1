Import-Module (Join-Path $PSScriptRoot "Awf.Util.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "Awf.Git.psm1") -Force

function Initialize-AwfCodeGraph {
    param([Parameter(Mandatory)][string]$RepoPath)

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
            indexer = "powershell-regex-mvp"
        } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -Encoding UTF8
    }
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
            if (($edge.from -like "*$f*") -or ($edge.to -like "*$f*")) {
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

function Update-AwfCodeGraph {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [switch]$ChangedOnly,
        [switch]$VerboseOutput
    )

    $graph = Join-Path $RepoPath ".wi/graph"
    $toolRoot = Split-Path -Parent $PSScriptRoot
    $config = Get-AwfConfig -RootPath $toolRoot
    $extensions = @($config.graph.extensions)
    $excludeDirectories = @($config.graph.excludeDirectories)
    $indexer = $config.graph.indexer
    $fileDiscovery = if ($ChangedOnly) { "git" } else { "unknown" }

    if ($ChangedOnly) {
        $relativeFiles = @(Get-AwfChangedFiles -RepoPath $RepoPath -Extensions $extensions -ExcludeDirectories $excludeDirectories)
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
            } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $graph "graph-state.json") -Encoding UTF8
            Write-AwfWarn "No changed source files detected."
            return
        }
    }
    else {
        $discovery = Get-AwfRepoFileDiscovery -RepoPath $RepoPath -Extensions $extensions -ExcludeDirectories $excludeDirectories
        $relativeFiles = @($discovery.files)
        $fileDiscovery = $discovery.method
        Set-Content -LiteralPath (Join-Path $graph "changed-files.txt") -Value @() -Encoding UTF8
    }

    if ($ChangedOnly) {
        Remove-AwfGraphEntriesForFiles -RepoPath $RepoPath -RelativeFiles $relativeFiles
    }
    else {
        Clear-AwfGraphEntries -RepoPath $RepoPath
    }

    foreach ($relative in $relativeFiles) {
        $full = Join-Path $RepoPath $relative
        if (!(Test-Path -LiteralPath $full)) { continue }

        $language = Get-AwfLanguage -Path $relative
        $kind = Get-AwfFileKind -Path $relative
        $content = Get-Content -LiteralPath $full -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($null -eq $content) { $content = "" }

        $hash = Get-AwfSha256 -Path $full
        $lineCount = ($content -split "`r?`n").Count
        $symbols = @(Get-AwfSymbolsFromContent -RelativePath $relative.Replace("\","/") -Content $content -Language $language)
        $edges = @(Get-AwfEdgesFromContent -RelativePath $relative.Replace("\","/") -Content $content -Symbols $symbols)
        $summary = Get-AwfFileSummary -RelativePath $relative.Replace("\","/") -Language $language -Kind $kind -Symbols $symbols

        Add-AwfJsonLine -Path (Join-Path $graph "files.jsonl") -Object ([pscustomobject]@{
            id = "file:$($relative.Replace("\","/"))"
            path = $relative.Replace("\","/")
            language = $language
            kind = $kind
            hash = $hash
            lineCount = $lineCount
            indexedUtc = (Get-Date).ToUniversalTime().ToString("o")
        })

        foreach ($s in $symbols) {
            $s | Add-Member -NotePropertyName hash -NotePropertyValue $hash -Force
            Add-AwfJsonLine -Path (Join-Path $graph "symbols.jsonl") -Object $s
        }

        foreach ($e in $edges) {
            Add-AwfJsonLine -Path (Join-Path $graph "edges.jsonl") -Object $e
        }

        Add-AwfJsonLine -Path (Join-Path $graph "summaries.jsonl") -Object $summary

        if ($VerboseOutput) {
            Write-AwfInfo "Indexed $relative ($($symbols.Count) symbols, $($edges.Count) edges)"
        }
    }

    @{
        version = "0.1.0"
        lastUpdatedUtc = (Get-Date).ToUniversalTime().ToString("o")
        changedOnly = [bool]$ChangedOnly
        indexedFileCount = $relativeFiles.Count
        indexer = $indexer
        fileDiscovery = $fileDiscovery
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
    "Get-AwfCodeGraphStatus"
)

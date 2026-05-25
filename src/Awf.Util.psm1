function Resolve-AwfPath {
    param([Parameter(Mandatory)][string]$Path)
    return (Resolve-Path -LiteralPath $Path).Path
}

function Write-AwfBanner {
    Write-Host ""
    Write-Host "AWF Code Graph Toolkit" -ForegroundColor Cyan
    Write-Host "Repo-local graph memory for AI agents" -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-AwfSuccess {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-AwfInfo {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-AwfWarn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Get-AwfSha256 {
    param([Parameter(Mandatory)][string]$Path)
    if (!(Test-Path -LiteralPath $Path)) { return $null }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function ConvertTo-AwfJsonLine {
    param([Parameter(ValueFromPipeline)]$InputObject)
    process {
        $InputObject | ConvertTo-Json -Compress -Depth 20
    }
}

function Add-AwfJsonLine {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object
    )
    $json = $Object | ConvertTo-Json -Compress -Depth 20
    Add-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Read-AwfJsonLines {
    param([Parameter(Mandatory)][string]$Path)
    if (!(Test-Path -LiteralPath $Path)) {
        throw "Graph JSONL file not found: $Path"
    }

    $lineNumber = 0
    Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object {
        $lineNumber++
        if (!$_.Trim()) { return }

        try {
            $_ | ConvertFrom-Json
        }
        catch {
            throw "Malformed JSONL in '$Path' at line $lineNumber."
        }
    }
}

function New-AwfDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (!(Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

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

function Test-AwfConfigProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    return ($Object.PSObject.Properties.Name -contains $Name)
}

function Assert-AwfNonEmptyString {
    param(
        [Parameter(Mandatory)][string]$Name,
        $Value
    )

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "Config value '$Name' must be a non-empty string."
    }
}

function Assert-AwfNonEmptyArray {
    param(
        [Parameter(Mandatory)][string]$Name,
        $Value
    )

    if ($null -eq $Value -or @($Value).Count -eq 0) {
        throw "Config value '$Name' must contain at least one item."
    }

    foreach ($item in @($Value)) {
        Assert-AwfNonEmptyString -Name $Name -Value $item
    }
}

function Assert-AwfPositiveInteger {
    param(
        [Parameter(Mandatory)][string]$Name,
        $Value
    )

    $text = [string]$Value
    if ($text -notmatch "^[1-9][0-9]*$") {
        throw "Config value '$Name' must be a positive whole number."
    }
}

function Assert-AwfConfigSection {
    param(
        [Parameter(Mandatory)][string]$Name,
        $Value
    )

    if ($null -eq $Value -or $Value.GetType().FullName -ne "System.Management.Automation.PSCustomObject") {
        throw "Config section '$Name' must be an object."
    }
}

function Assert-AwfOptionalString {
    param(
        [Parameter(Mandatory)][string]$Name,
        $Value
    )

    if ($null -eq $Value) {
        return
    }

    Assert-AwfNonEmptyString -Name $Name -Value $Value
}

function Get-AwfConfig {
    param([string]$RootPath)

    $config = Get-AwfDefaultConfig
    $configPath = Join-Path $RootPath "config/awf-codegraph.config.json"
    if (Test-Path -LiteralPath $configPath) {
        try {
            $candidate = Get-AwfDefaultConfig
            $loaded = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

            if (Test-AwfConfigProperty -Object $loaded -Name "version") {
                Assert-AwfNonEmptyString -Name "version" -Value $loaded.version
                $candidate.version = $loaded.version
            }

            if (Test-AwfConfigProperty -Object $loaded -Name "graph") {
                Assert-AwfConfigSection -Name "graph" -Value $loaded.graph
                if (Test-AwfConfigProperty -Object $loaded.graph -Name "workspace") {
                    Assert-AwfNonEmptyString -Name "graph.workspace" -Value $loaded.graph.workspace
                    $candidate.graph.workspace = $loaded.graph.workspace
                }
                if (Test-AwfConfigProperty -Object $loaded.graph -Name "runtime") {
                    Assert-AwfNonEmptyString -Name "graph.runtime" -Value $loaded.graph.runtime
                    $candidate.graph.runtime = $loaded.graph.runtime
                }
                if (Test-AwfConfigProperty -Object $loaded.graph -Name "logs") {
                    Assert-AwfNonEmptyString -Name "graph.logs" -Value $loaded.graph.logs
                    $candidate.graph.logs = $loaded.graph.logs
                }
                if (Test-AwfConfigProperty -Object $loaded.graph -Name "indexer") {
                    Assert-AwfNonEmptyString -Name "graph.indexer" -Value $loaded.graph.indexer
                    $candidate.graph.indexer = $loaded.graph.indexer
                }
                if (Test-AwfConfigProperty -Object $loaded.graph -Name "extensions") {
                    Assert-AwfNonEmptyArray -Name "graph.extensions" -Value $loaded.graph.extensions
                    $candidate.graph.extensions = @($loaded.graph.extensions)
                }
                if (Test-AwfConfigProperty -Object $loaded.graph -Name "excludeDirectories") {
                    Assert-AwfNonEmptyArray -Name "graph.excludeDirectories" -Value $loaded.graph.excludeDirectories
                    $candidate.graph.excludeDirectories = @($loaded.graph.excludeDirectories)
                }
            }

            if (Test-AwfConfigProperty -Object $loaded -Name "contextPacket") {
                Assert-AwfConfigSection -Name "contextPacket" -Value $loaded.contextPacket
                if (Test-AwfConfigProperty -Object $loaded.contextPacket -Name "maxSymbols") {
                    Assert-AwfPositiveInteger -Name "contextPacket.maxSymbols" -Value $loaded.contextPacket.maxSymbols
                    $candidate.contextPacket.maxSymbols = [int]$loaded.contextPacket.maxSymbols
                }
                if (Test-AwfConfigProperty -Object $loaded.contextPacket -Name "maxSummaries") {
                    Assert-AwfPositiveInteger -Name "contextPacket.maxSummaries" -Value $loaded.contextPacket.maxSummaries
                    $candidate.contextPacket.maxSummaries = [int]$loaded.contextPacket.maxSummaries
                }
                if (Test-AwfConfigProperty -Object $loaded.contextPacket -Name "maxRecommendedFiles") {
                    Assert-AwfPositiveInteger -Name "contextPacket.maxRecommendedFiles" -Value $loaded.contextPacket.maxRecommendedFiles
                    $candidate.contextPacket.maxRecommendedFiles = [int]$loaded.contextPacket.maxRecommendedFiles
                }
            }

            if (Test-AwfConfigProperty -Object $loaded -Name "upgradeHooks") {
                Assert-AwfConfigSection -Name "upgradeHooks" -Value $loaded.upgradeHooks
                if (Test-AwfConfigProperty -Object $loaded.upgradeHooks -Name "dotnetRoslynIndexerCommand") {
                    Assert-AwfOptionalString -Name "upgradeHooks.dotnetRoslynIndexerCommand" -Value $loaded.upgradeHooks.dotnetRoslynIndexerCommand
                    $candidate.upgradeHooks.dotnetRoslynIndexerCommand = $loaded.upgradeHooks.dotnetRoslynIndexerCommand
                }
                if (Test-AwfConfigProperty -Object $loaded.upgradeHooks -Name "treeSitterIndexerCommand") {
                    Assert-AwfOptionalString -Name "upgradeHooks.treeSitterIndexerCommand" -Value $loaded.upgradeHooks.treeSitterIndexerCommand
                    $candidate.upgradeHooks.treeSitterIndexerCommand = $loaded.upgradeHooks.treeSitterIndexerCommand
                }
                if (Test-AwfConfigProperty -Object $loaded.upgradeHooks -Name "codeQlDatabaseCommand") {
                    Assert-AwfOptionalString -Name "upgradeHooks.codeQlDatabaseCommand" -Value $loaded.upgradeHooks.codeQlDatabaseCommand
                    $candidate.upgradeHooks.codeQlDatabaseCommand = $loaded.upgradeHooks.codeQlDatabaseCommand
                }
            }

            $config = $candidate
        }
        catch {
            Write-AwfWarn "Failed to read config at $configPath. Using built-in defaults."
        }
    }

    return $config
}

function Test-AwfCommandAvailable {
    param([Parameter(Mandatory)][string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    return ($null -ne $command)
}

Export-ModuleMember -Function @(
    "Resolve-AwfPath",
    "Write-AwfBanner",
    "Write-AwfSuccess",
    "Write-AwfInfo",
    "Write-AwfWarn",
    "Get-AwfSha256",
    "ConvertTo-AwfJsonLine",
    "Add-AwfJsonLine",
    "Read-AwfJsonLines",
    "New-AwfDirectory",
    "Get-AwfDefaultConfig",
    "Get-AwfConfig",
    "Test-AwfCommandAvailable"
)

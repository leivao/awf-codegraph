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

    [switch]$VerboseOutput,

    [ValidateSet("powershell", "roslyn")]
    [string]$Indexer
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$AwfUtilModule = Import-Module (Join-Path $Root "src/Awf.Util.psm1") -Force -PassThru
Import-Module (Join-Path $Root "src/Awf.Git.psm1") -Force | Out-Null
$AwfCodeGraphModule = Import-Module (Join-Path $Root "src/Awf.CodeGraph.psm1") -Force -PassThru
$AwfContextPacketModule = Import-Module (Join-Path $Root "src/Awf.ContextPacket.psm1") -Force -PassThru
$AwfAgentBootstrapModule = Import-Module (Join-Path $Root "src/Awf.AgentBootstrap.psm1") -Force -PassThru

$validCommands = @("init", "update", "impact", "context", "query", "status")

if ($AreaOrCommand -eq "agents") {
    if ($Command -ne "install") {
        throw "Unknown agents command '$Command'. Valid commands: install."
    }
}
elseif ($AreaOrCommand -eq "graph") {
    if ([string]::IsNullOrWhiteSpace($Command)) {
        $Command = "status"
    }
}
else {
    if (![string]::IsNullOrWhiteSpace($Command)) {
        throw "Unexpected argument '$Command'. Use: awf-graph $AreaOrCommand [options]."
    }

    $Command = $AreaOrCommand

    if ($validCommands -notcontains $Command) {
        throw "Unknown command '$Command'. Valid commands: $($validCommands -join ', ')."
    }
}

$ResolveAwfPath = $AwfUtilModule.ExportedCommands["Resolve-AwfPath"]
$WriteAwfBanner = $AwfUtilModule.ExportedCommands["Write-AwfBanner"]
$WriteAwfSuccess = $AwfUtilModule.ExportedCommands["Write-AwfSuccess"]
$InitializeAwfCodeGraph = $AwfCodeGraphModule.ExportedCommands["Initialize-AwfCodeGraph"]
$UpdateAwfCodeGraph = $AwfCodeGraphModule.ExportedCommands["Update-AwfCodeGraph"]
$NewAwfImpactReport = $AwfCodeGraphModule.ExportedCommands["New-AwfImpactReport"]
$SearchAwfCodeGraph = $AwfCodeGraphModule.ExportedCommands["Search-AwfCodeGraph"]
$GetAwfCodeGraphStatus = $AwfCodeGraphModule.ExportedCommands["Get-AwfCodeGraphStatus"]
$NewAwfContextPacket = $AwfContextPacketModule.ExportedCommands["New-AwfContextPacket"]
$InstallAwfAgentBootstrap = $AwfAgentBootstrapModule.ExportedCommands["Install-AwfAgentBootstrap"]

$resolvedRepo = & $ResolveAwfPath -Path $RepoPath

& $WriteAwfBanner

if ($AreaOrCommand -eq "agents") {
    & $InstallAwfAgentBootstrap -RepoPath $resolvedRepo
    return
}

switch ($Command) {
    "init" {
        & $InitializeAwfCodeGraph -RepoPath $resolvedRepo
        & $WriteAwfSuccess "Code graph workspace initialized at $resolvedRepo\.wi\graph"
    }

    "update" {
        & $InitializeAwfCodeGraph -RepoPath $resolvedRepo | Out-Null
        if ($PSBoundParameters.ContainsKey("Indexer")) {
            & $UpdateAwfCodeGraph -RepoPath $resolvedRepo -ChangedOnly:$ChangedOnly -VerboseOutput:$VerboseOutput -Indexer $Indexer
        }
        else {
            & $UpdateAwfCodeGraph -RepoPath $resolvedRepo -ChangedOnly:$ChangedOnly -VerboseOutput:$VerboseOutput
        }
        & $WriteAwfSuccess "Code graph updated."
    }

    "impact" {
        & $InitializeAwfCodeGraph -RepoPath $resolvedRepo | Out-Null
        $impactPath = & $NewAwfImpactReport -RepoPath $resolvedRepo
        & $WriteAwfSuccess "Impact report created: $impactPath"
    }

    "context" {
        & $InitializeAwfCodeGraph -RepoPath $resolvedRepo | Out-Null
        $contextPath = & $NewAwfContextPacket -RepoPath $resolvedRepo -TaskFile $TaskFile -Query $Query
        & $WriteAwfSuccess "Context packet created: $contextPath"
    }

    "query" {
        if ([string]::IsNullOrWhiteSpace($Query)) {
            throw "Query is required for graph query."
        }
        & $SearchAwfCodeGraph -RepoPath $resolvedRepo -Query $Query | Format-Table -AutoSize
    }

    "status" {
        & $GetAwfCodeGraphStatus -RepoPath $resolvedRepo | Format-List
    }
}

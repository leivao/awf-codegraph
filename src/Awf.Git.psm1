Import-Module (Join-Path $PSScriptRoot "Awf.Util.psm1") -Force

function Test-AwfGitRepo {
    param([Parameter(Mandatory)][string]$RepoPath)
    $old = Get-Location
    try {
        Set-Location $RepoPath
        git rev-parse --is-inside-work-tree 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    }
    finally {
        Set-Location $old
    }
}

function ConvertTo-AwfRelativePath {
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$FullPath
    )

    $base = (Resolve-Path -LiteralPath $BasePath).Path.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $full = (Resolve-Path -LiteralPath $FullPath).Path
    $comparison = [System.StringComparison]::OrdinalIgnoreCase

    if ($full.Equals($base, $comparison)) {
        return "."
    }

    $prefix = $base + [System.IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($prefix, $comparison)) {
        return $full.Substring($prefix.Length)
    }

    throw "Path '$FullPath' is not under base path '$BasePath'."
}

function Get-AwfChangedFiles {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [string[]]$Extensions = @(".cs", ".ts", ".tsx", ".js", ".jsx", ".py", ".json", ".csproj", ".sln", ".props", ".targets"),
        [string[]]$ExcludeDirectories = @(".git", ".wi", "node_modules", "bin", "obj", "dist", "build")
    )

    $extensionSet = @{}
    foreach ($ext in $Extensions) {
        if (![string]::IsNullOrWhiteSpace($ext)) {
            $extensionSet[$ext.ToLowerInvariant()] = $true
        }
    }

    $excludeNames = @($ExcludeDirectories | Where-Object { ![string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [regex]::Escape($_) })
    $excludePattern = if ($excludeNames.Count -gt 0) {
        "(^|[\\/])(" + ($excludeNames -join "|") + ")([\\/]|$)"
    }
    else {
        $null
    }

    function Select-AwfIndexableChangedFile {
        param([AllowEmptyCollection()][string[]]$Files)

        $Files |
            Where-Object { $_ } |
            Where-Object {
                $ext = [System.IO.Path]::GetExtension($_).ToLowerInvariant()
                $extensionSet.ContainsKey($ext) -and (!$excludePattern -or ($_ -notmatch $excludePattern))
            } |
            Sort-Object -Unique
    }

    $old = Get-Location
    try {
        Set-Location $RepoPath

        $files = @()
        $oldErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $tracked = git diff --name-only HEAD 2>$null
            $staged = git diff --name-only --cached 2>$null
            $untracked = git ls-files --others --exclude-standard 2>$null
        }
        finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }

        $files += $tracked
        $files += $staged
        $files += $untracked

        $indexableFiles = @(Select-AwfIndexableChangedFile -Files $files)
        if ($indexableFiles.Count -gt 0) {
            return $indexableFiles
        }

        $oldErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $lastCommitFiles = @(git diff-tree --root --no-commit-id --name-only -r HEAD 2>$null)
        }
        finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }

        Select-AwfIndexableChangedFile -Files $lastCommitFiles
    }
    finally {
        Set-Location $old
    }
}

function Get-AwfRepoFiles {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [string[]]$Extensions = @(".cs", ".ts", ".tsx", ".js", ".jsx", ".py", ".json", ".csproj", ".sln", ".props", ".targets"),
        [string[]]$ExcludeDirectories = @(".git", ".wi", "node_modules", "bin", "obj", "dist", "build"),
        [switch]$UsePowerShellFallback
    )

    $script:AwfLastFileDiscoveryMethod = "powershell"
    $extensionSet = @{}
    foreach ($ext in $Extensions) {
        if (![string]::IsNullOrWhiteSpace($ext)) {
            $extensionSet[$ext.ToLowerInvariant()] = $true
        }
    }

    $excludeNames = @($ExcludeDirectories | Where-Object { ![string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [regex]::Escape($_) })
    $excludePattern = if ($excludeNames.Count -gt 0) {
        "(^|[\\/])(" + ($excludeNames -join "|") + ")([\\/]|$)"
    }
    else {
        $null
    }

    if (!$UsePowerShellFallback -and (Test-AwfCommandAvailable -Name "rg")) {
        $old = Get-Location
        try {
            Set-Location $RepoPath
            $rgFiles = @(rg --files)
            if ($LASTEXITCODE -eq 0) {
                $script:AwfLastFileDiscoveryMethod = "rg"
                return @($rgFiles |
                Where-Object {
                    $ext = [System.IO.Path]::GetExtension($_).ToLowerInvariant()
                    $extensionSet.ContainsKey($ext) -and (!$excludePattern -or ($_ -notmatch $excludePattern))
                } |
                Sort-Object -Unique)
            }
        }
        finally {
            Set-Location $old
        }

        Write-AwfWarn "rg file discovery failed. Falling back to PowerShell file discovery."
    }

    Get-ChildItem -LiteralPath $RepoPath -Recurse -File |
        Where-Object {
            $relativePath = ConvertTo-AwfRelativePath -BasePath $RepoPath -FullPath $_.FullName
            (!$excludePattern -or ($relativePath -notmatch $excludePattern)) -and
            $extensionSet.ContainsKey($_.Extension.ToLowerInvariant())
        } |
        ForEach-Object {
            ConvertTo-AwfRelativePath -BasePath $RepoPath -FullPath $_.FullName
        } |
        Sort-Object -Unique
}

function Get-AwfRepoFileDiscovery {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [string[]]$Extensions = @(".cs", ".ts", ".tsx", ".js", ".jsx", ".py", ".json", ".csproj", ".sln", ".props", ".targets"),
        [string[]]$ExcludeDirectories = @(".git", ".wi", "node_modules", "bin", "obj", "dist", "build")
    )

    $method = Get-AwfFileDiscoveryMethod
    $files = @(Get-AwfRepoFiles -RepoPath $RepoPath -Extensions $Extensions -ExcludeDirectories $ExcludeDirectories)

    return [pscustomobject]@{
        files = $files
        method = $script:AwfLastFileDiscoveryMethod
    }
}

function Get-AwfFileDiscoveryMethod {
    if (Test-AwfCommandAvailable -Name "rg") {
        return "rg"
    }

    return "powershell"
}

Export-ModuleMember -Function @(
    "Test-AwfGitRepo",
    "ConvertTo-AwfRelativePath",
    "Get-AwfChangedFiles",
    "Get-AwfRepoFiles",
    "Get-AwfRepoFileDiscovery",
    "Get-AwfFileDiscoveryMethod"
)

[CmdletBinding()]
param(
    [string]$DemoRepoPath = "./demo-repo"
)

$ErrorActionPreference = "Stop"

if (Test-Path -LiteralPath $DemoRepoPath) {
    Remove-Item -LiteralPath $DemoRepoPath -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $DemoRepoPath | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $DemoRepoPath "src/Students") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $DemoRepoPath "tests/Students") | Out-Null

@"
namespace Demo.Students;

public class StudentService
{
    public Student CreateStudent(CreateStudentRequest request)
    {
        Validate(request);
        return new Student();
    }

    private void Validate(CreateStudentRequest request)
    {
    }
}
"@ | Set-Content -LiteralPath (Join-Path $DemoRepoPath "src/Students/StudentService.cs") -Encoding UTF8

@"
namespace Demo.Students;

public class StudentServiceTests
{
    public void CreateStudent_WhenValid_ReturnsStudent()
    {
    }
}
"@ | Set-Content -LiteralPath (Join-Path $DemoRepoPath "tests/Students/StudentServiceTests.cs") -Encoding UTF8

Push-Location $DemoRepoPath
git init | Out-Null
git add . | Out-Null
git commit -m "Initial demo repo" | Out-Null
Pop-Location

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
& (Join-Path $root "awf.ps1") graph init -RepoPath $DemoRepoPath
& (Join-Path $root "awf.ps1") graph update -RepoPath $DemoRepoPath
& (Join-Path $root "awf.ps1") graph query -RepoPath $DemoRepoPath -Query "StudentService"
& (Join-Path $root "awf.ps1") graph context -RepoPath $DemoRepoPath -Query "StudentService"

Write-Host "Demo completed. Inspect $DemoRepoPath/.wi/runtime/context-packet.md" -ForegroundColor Green

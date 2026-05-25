$ErrorActionPreference = "Stop"
Import-Module ./src/Awf.Util.psm1 -Force
$path = Join-Path (Get-Location).Path ('.final-review-jsonl-blank-' + [guid]::NewGuid().ToString('N') + '.jsonl')
Set-Content -LiteralPath $path -Value @('', '{"a":1}') -Encoding UTF8
$items = @(Read-AwfJsonLines $path)
"items=$($items.Count); first=$($items[0].a)"

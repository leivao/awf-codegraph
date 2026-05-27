# AWF Code Graph PowerShell Toolkit

A user-level, PowerShell-first **Code Graph + Context Packet** layer for AI coding agents.

It is designed to reduce AI token consumption by helping agents read only the relevant files, symbols, relationships, and tests instead of repeatedly scanning the entire repository.

## Core idea

```text
Repo source code
   -> AWF Code Graph
      -> Impact Analysis
         -> AI Context Packet
            -> Codex / Claude / Copilot / Ollama
```

PowerShell acts as the workflow conductor. The included MVP indexer is implemented in PowerShell and is intentionally dependency-light. For C# repositories, `awf-graph update -Indexer roslyn` now upgrades only the C# path to the bundled Roslyn console indexer while leaving non-C# files on the PowerShell path.

## Included components

```text
awf.ps1
config/awf-codegraph.config.json
src/Awf.CodeGraph.psm1
src/Awf.Git.psm1
src/Awf.ContextPacket.psm1
src/Awf.Util.psm1
scripts/install.ps1
scripts/demo.ps1
templates/context-packet.template.md
templates/agent-instructions.md
docs/design.md
docs/agent-workflow.md
docs/roslyn-upgrade-path.md
examples/sample-task.json
```

## Commands

Install the user-level command:

```powershell
.\scripts\install.ps1
```

If Windows blocks unsigned PowerShell scripts, use the command wrapper instead:

```cmd
scripts\install.cmd
```

The installer creates a user-level `awf-graph` command. Optional tools such as `rg` and `gh` are detected during install. Missing optional tools are only installed with explicit consent through `winget`.

Upgrade an existing user-level install from this source tree:

```powershell
.\scripts\upgrade.ps1
```

Or, when execution policy blocks unsigned scripts:

```cmd
scripts\upgrade.cmd
```

Uninstall the user-level toolkit and launcher:

```powershell
.\scripts\uninstall.ps1
```

Or, when execution policy blocks unsigned scripts:

```cmd
scripts\uninstall.cmd
```

Uninstall removes the installed toolkit directory and the AWF `bin` entry from the current user's PATH. It does not remove repo-local `.wi` folders, generated graph files, or project Git hooks.

Then run from any project repo:

```powershell
awf-graph init
awf-graph update
awf-graph update -Indexer roslyn
awf-graph update -ChangedOnly
awf-graph update -ChangedOnly -Indexer roslyn
awf-graph impact
awf-graph context -TaskFile ".\story.json"
awf-graph query -Query "StudentService"
awf-graph agents install
```

From this toolkit repo, you can also try the sample task with:

```powershell
awf-graph context -TaskFile ".\examples\sample-task.json"
```

## Generated repo-local files

```text
.wi/
  graph/
    files.jsonl
    symbols.jsonl
    edges.jsonl
    summaries.jsonl
    graph-state.json
    changed-files.txt
    impact.md
  runtime/
    context-packet.md
    context-packet.json
    <copied-task-file>
  logs/
    progress.ndjson
```

## Recommended agent flow

```text
1. Human provides story/task.
2. AWF graph init/update runs.
3. AWF generates context packet.
4. AI agent receives:
   - story/task
   - context packet
   - impacted files
   - changed symbols
   - relevant tests
5. Agent modifies code.
6. `awf-graph update -ChangedOnly` runs.
7. AWF impact/review packet is generated.
8. Reviewer agent validates against task and graph impact.
```

## Agent bootstrap

Install repo-local Codex, GitHub Copilot, generic agent instructions, and a best-effort post-commit graph refresh hook:

```powershell
awf-graph agents install
```

This creates or updates:

```text
.codex/skills/awf-codegraph/SKILL.md
.github/copilot-instructions.md
.wi/agent-instructions.md
.git/hooks/post-commit
```

If `.github/copilot-instructions.md` already exists, AWF preserves project content and updates only the AWF-marked section.

## MVP limitations

This package uses regex-based parsing for portability. It is useful as a working graph memory layer, but not a perfect semantic compiler-level graph.

For production-grade .NET precision, use the bundled mixed update path in `docs/roslyn-upgrade-path.md`. Roslyn indexing requires a discoverable `.sln` and only replaces the C# side of the graph.

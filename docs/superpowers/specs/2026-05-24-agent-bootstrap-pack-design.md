# AWF Agent Bootstrap Pack Design

## Goal

Add an AWF command that installs repo-local agent guidance for Codex and GitHub Copilot, plus a non-blocking post-commit hook that refreshes the code graph after commits.

The feature should make `.wi` graph artifacts the first point of reference for AI coding agents before they plan, implement, debug, review, or invoke deeper skills. Agents still verify exact source files before editing because the graph is an index, not the source of truth.

## User Experience

From any project repository with AWF installed:

```powershell
awf-graph agents install
```

The command creates or updates:

```text
.codex/skills/awf-codegraph/SKILL.md
.github/copilot-instructions.md
.wi/agent-instructions.md
.git/hooks/post-commit
```

The command is idempotent. Re-running it refreshes AWF-managed content without removing unrelated user content.

## Generated Agent Guidance

All generated instructions share the same behavior contract:

1. Before broad repo scans, read `.wi/runtime/context-packet.md` if it exists.
2. Use `.wi/graph/files.jsonl`, `.wi/graph/symbols.jsonl`, `.wi/graph/edges.jsonl`, and `.wi/graph/summaries.jsonl` as the first navigation source.
3. Use `.wi/graph/impact.md` during review and regression analysis.
4. Treat graph data as guidance only; verify exact source before editing.
5. After edits, run `awf-graph update -ChangedOnly` and `awf-graph impact`.
6. Summarize changed files, changed symbols, tests run, and residual risks.

Codex receives this contract as a skill at `.codex/skills/awf-codegraph/SKILL.md`.

GitHub Copilot receives this contract through `.github/copilot-instructions.md`. If the file already exists, AWF updates only the section between:

```text
<!-- BEGIN AWF CODE GRAPH -->
<!-- END AWF CODE GRAPH -->
```

Generic agents receive the same guidance at `.wi/agent-instructions.md`.

## Git Hook Behavior

The installed hook is a `post-commit` hook. It is best-effort and non-blocking.

After a successful commit, the hook runs:

```powershell
awf-graph update -ChangedOnly
awf-graph impact
```

If either command fails, the hook prints a warning and exits successfully so it never invalidates an already-created commit.

The hook must work from a Git hook context where the working directory may differ from a normal shell. It should resolve the repository root with Git and pass it to AWF with `-RepoPath`.

## Manual Project Configuration

Projects can adopt the same behavior manually without running `awf-graph agents install`.

Manual Codex setup:

```text
.codex/skills/awf-codegraph/SKILL.md
```

Copy the AWF Codex skill template into that path. The skill should instruct Codex to consult `.wi/runtime/context-packet.md` and `.wi/graph/*` before other implementation, debugging, or review work.

Manual Copilot setup:

```text
.github/copilot-instructions.md
```

Add the AWF code graph section to the file. If project-specific Copilot instructions already exist, keep them and add the AWF section under the AWF markers.

Manual generic setup:

```text
.wi/agent-instructions.md
```

Copy the generic AWF agent instructions into this path for agents that do not support Codex skills or Copilot instructions.

Manual hook setup:

```text
.git/hooks/post-commit
```

Create a hook that runs:

```powershell
awf-graph update -ChangedOnly -RepoPath "<repo-root>"
awf-graph impact -RepoPath "<repo-root>"
```

The hook should be best-effort and should not block or fail commits.

## Command Design

Extend `awf.ps1` so it accepts:

```powershell
awf-graph agents install
```

The command dispatches to a new module:

```text
src/Awf.AgentBootstrap.psm1
```

The module owns:

- creating parent directories
- rendering templates
- updating marked sections in existing files
- detecting whether the target path is a Git repository
- installing the post-commit hook when `.git` exists
- reporting which files were created, updated, skipped, or warned

## Templates

Add templates:

```text
templates/codex-awf-codegraph-skill.md
templates/copilot-instructions.md
templates/git-hooks/post-commit
```

Keep `templates/agent-instructions.md` as the generic instruction source, updating it if needed so it matches the same behavior contract.

## Error Handling

If the target repo has no `.git` directory, the command still installs agent instruction files and warns that the Git hook was skipped.

If `.github/copilot-instructions.md` exists without AWF markers, the command appends an AWF-managed section instead of replacing the file.

If a generated file cannot be written, the command throws with the path and reason.

## Testing

Add focused tests for:

- creating Codex, Copilot, generic, and hook files in a fresh repo
- updating an existing Copilot instruction file without deleting user content
- replacing an existing AWF-marked Copilot section
- skipping hook installation outside a Git repo
- verifying the post-commit hook contains best-effort AWF update and impact commands

## Out of Scope

- No Superpowers-specific generated skill.
- No pre-commit blocking behavior.
- No automatic installation into global Codex or Copilot user configuration.
- No dependency on GitHub CLI.

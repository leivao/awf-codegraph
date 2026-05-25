# AWF Code Graph Design

## Goal

Implement a local code graph that helps AI coding agents minimize token usage while improving repo navigation, impact analysis, and review quality.

## Design principles

1. Artifacts over transcript replay.
2. Incremental updates over full re-indexing.
3. Parser-derived graph before AI-generated summaries.
4. AI summaries cached by file hash.
5. Context packets over full repo reads.
6. PowerShell as orchestration layer, specialized analyzers as optional upgrades.

## Data model

### files.jsonl

```json
{
  "id": "file:src/Core/StudentService.cs",
  "path": "src/Core/StudentService.cs",
  "language": "csharp",
  "kind": "service",
  "hash": "sha256",
  "lineCount": 100,
  "indexedUtc": "..."
}
```

### symbols.jsonl

```json
{
  "id": "symbol:src/Core/StudentService.cs#StudentService.CreateAsync",
  "type": "method",
  "name": "CreateAsync",
  "container": "StudentService",
  "file": "src/Core/StudentService.cs",
  "language": "csharp",
  "startLine": 42,
  "endLine": null,
  "signature": "public async Task<Student> CreateAsync(...)",
  "hash": "sha256"
}
```

### edges.jsonl

```json
{
  "from": "file:src/Core/StudentService.cs",
  "to": "symbol:src/Core/StudentService.cs#StudentService",
  "type": "defines",
  "confidence": "high",
  "source": "powershell-regex-mvp"
}
```

### summaries.jsonl

```json
{
  "file": "src/Core/StudentService.cs",
  "language": "csharp",
  "kind": "service",
  "summary": "Contains service code. Key symbols: StudentService, CreateAsync.",
  "generatedBy": "heuristic",
  "generatedUtc": "..."
}
```

## Workflow

```text
graph init
graph update
graph context
agent implementation
graph update --changed-only
graph impact
review agent
tests/build
```

## Recommended evolution

1. MVP regex parser.
2. Roslyn for C# symbol and call graph.
3. TypeScript compiler API for TS/React.
4. Tree-sitter for multi-language support.
5. SQLite store for faster queries.
6. Optional CodeQL integration for security/deep semantic queries.

# Agent Workflow with Code Graph

## Intake

Input:
- story or task
- acceptance criteria
- repo path
- optional extra prompt

Actions:
```powershell
awf-graph init
awf-graph update
awf-graph context -TaskFile .\story.json -Query "domain keyword"
```

Output:
- `.wi/runtime/context-packet.md`
- `.wi/runtime/context-packet.json`

## Planning agent

The planning agent receives:
- task/story
- context packet
- graph summaries
- recommended files

It produces:
- plan
- impacted areas
- proposed files to edit
- expected tests

## Implementation agent

The implementation agent:
- reads only recommended files first
- edits code
- runs build/tests
- updates graph

Commands:
```powershell
awf-graph update -ChangedOnly
awf-graph impact
```

## Review agent

The review agent receives:
- story/task
- git diff
- `.wi/graph/impact.md`
- `.wi/runtime/context-packet.md`
- `.wi/runtime/context-packet.json`
- test output

It validates:
- acceptance criteria
- changed symbol impact
- tests
- regressions
- unnecessary changes
- architecture consistency

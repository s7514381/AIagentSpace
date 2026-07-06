# 2026-06-24 Recent Changes Priority

Scope: `C:\Users\s7514\Desktop\AI Agent Space`

Change:

Added the rule that newer changes should be read first when memory search results are similarly relevant, overlapping, or conflicting.

Ordering:

1. Task relevance and project match.
2. Status, preferring `active`.
3. Recency by `updatedAt`, then `createdAt`, then `timestamp`.
4. Importance as the final tie-breaker.

Safety:

Newer `unverified` records do not override older verified active records without rechecking.

Files touched:

- `AGENT_BOOTSTRAP.md`
- `主要引導.md`
- `記憶系統規格.md`
- `Memories/README.md`
- `Memories/index/startup-index.json`
- `Memories/config/memory-rules.json`
- `Memories/scripts/validate-memory.ps1`
- `Memories/index/summaries.jsonl`

Verification:

```text
JSON files: 6
JSONL files: 8
JSONL records: 30
Warnings: 0
Memory validation passed.
```

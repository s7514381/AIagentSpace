# Semantic Consolidation Task Template

## 目標

審核 `Memories/inbox/*.json` 中的 pending evidence packets，將真正有長期價值的內容升級到正式記憶索引；沒有長期價值的 packet 應封存或標記 rejected。

## 核心原則

1. `TaskComplete Hook` 沒有理解力，只能提供 evidence packet。
2. `aiCandidate` 預設不可信，只能當摘要提示。
3. 正式記憶必須有 evidence metadata。
4. 不確定的內容只能標 `unverified`，不可寫成 active stable fact。
5. 不要把一次性閒聊、無後續價值的細節寫入正式索引。

## 建議步驟

1. 讀取 `Memories/config/consolidation-policy.json`。
2. 列出 `Memories/inbox/*.json`，優先處理：
   - `status = pending_review`
   - oldest packets
   - memory-system / hook / bug-fix / decision 相關 tags
3. 對每個 packet 檢查：
   - `task.prompt`
   - `evidence.git.changedFiles`
   - `evidence.git.diffStat`
   - `aiCandidate.resultPreview`（只作提示）
   - 是否包含使用者明確陳述
4. 判斷是否升級：
   - 使用者穩定偏好 → `Memories/index/preferences.json`
   - 跨專案決策 → `Memories/index/decisions.jsonl`
   - 一般摘要 → `Memories/index/summaries.jsonl`
   - 專案事實 → `Memories/projects/<project>/facts.jsonl`
   - 專案決策 → `Memories/projects/<project>/decisions.jsonl`
   - 警告/踩雷 → `Memories/projects/<project>/warnings.jsonl`
   - bug fix → `Memories/projects/<project>/bug-fixes.jsonl`
5. 每筆正式記憶都加入：

```json
{
  "evidence": {
    "level": "verified",
    "sources": ["Memories/inbox/<packet>.json"],
    "reviewedBy": "semantic_consolidation_task",
    "reviewedAt": "YYYY-MM-DD HH:mm:ss"
  }
}
```

6. 處理完成的 packet：
   - 更新 `status` 為 `consolidated` / `archived` / `rejected` / `needs_more_evidence`
   - 加上 `reviewedAt`、`reviewResult`、`promotedTo`
   - 移到 `Memories/inbox/archive/`，或保留原地但不可再算 pending。
7. 執行 `Memories/scripts/validate-memory.ps1`。

## 完成條件

- inbox pending count 降低。
- 正式索引 JSON/JSONL 驗證通過。
- 所有升級記憶都有 evidence metadata。
- startup-index 只保留每次任務必需知道的短規則。
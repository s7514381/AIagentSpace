# Agent Bootstrap

這是每次任務的短版必讀入口。它只放高頻、不可跳過的規則；完整規格依需要再讀長版文件。

## 前置閱讀 Token 預算

每次對話開始的固定必讀內容，合計不得超過 **5000 tokens**：

- `AGENT_BOOTSTRAP.md`（本文件）
- repo `AGENTS.md`（專案入口）
- `Memories/index/startup-index.json`（壓縮啟動索引）
- `Memories/logs/index.md`（近期任務日誌索引，掃前 10 筆或累積至 3000 tokens）

若超過預算，優先壓縮 `startup-index.json` 與 `logs/index.md`，不刪除 `AGENT_BOOTSTRAP.md`、`主要引導.md` 或 `AGENTS.md` 必要規則。

## 讀取順序（Hook 自動執行）

> **TaskStart Hook**（`C:\Users\s7514\Documents\Cline\Hooks\TaskStart.ps1`）會自動執行以下步驟，AI 不需要手動操作。

0. 讀 `主要引導.md`，取得 AI Agent Space 總入口與文件地圖。
1. 讀本文件。
2. 讀目前 repo 的 `AGENTS.md`，確認專案適配文件位置。
3. **Hook 自動讀取** `Memories/index/startup-index.json`，取得高頻偏好、路徑與 token 預算。
4. **Hook 自動讀取** `Memories/logs/index.md`，掃描最新前 10 筆任務日誌（累積至 3000 tokens），取得近期任務脈絡。
5. **Hook 自動萃取關鍵字**：從任務描述中取出英文專有名詞，搜尋所有 JSONL 索引。
6. **Hook 自動回傳 contextModification**：包含關鍵字、相關記憶摘要（前 8 筆）、近期任務日誌。
7. 只有 `startup-index.json` 不足、需要偏好細節或要修改記憶規則時，才讀 `Memories/index/agent-profile.json` 與 `Memories/index/preferences.json`。
8. 任務涉及程式碼、架構、資料、權限或驗證時，讀 `DEVELOPMENT_PRINCIPLES.md`。
9. 依 `AGENTS.md` 指示讀專案適配文件；若任務很小，先讀摘要或相關章節，必要時再讀全文。
10. 只有摘要不足時，才依 `rawPath` 讀 `Memories/raw/**`。

## 必守規則

1. 開始修改前先輸出原則讀取回執；小任務可用極簡回執。
2. 回執需列出：已讀文件、記憶搜尋關鍵字、本次適用原則或最小範圍、驗證方式。
3. 先讀現況，再做判斷；不要憑檔名、慣例或過去經驗猜。
4. 沿用既有架構、工具鏈與專案適配規則，不平行新建一套。
5. 修改範圍貼近需求，不做無關重構。
6. 依賴資料內容、外部狀態或環境時，先查證再改。
7. 完成後能驗證就驗證；不能驗證要說明 blocker 與替代檢查。
8. 每次聊天結束前評估是否寫回長期記憶。

## 何時讀長版

讀 `記憶系統規格.md`：

- 要修改記憶系統、資料夾結構、寫入規則、索引規則。
- 要調整 Project Memory、檢索優先順序、淘汰規則或 agent profile。

讀 `DEVELOPMENT_PRINCIPLES.md`：

- 要改程式碼、架構、資料流、權限、安全、驗證流程。
- 專案適配文件與需求有衝突。

讀專案適配文件全文：

- 任務涉及該專案的程式碼、DB、前端、登入、MCP、測試、部署或特殊規則。

## 任務日誌規則

- 每次對話結束前，必須在 `Memories/logs/` 寫入任務日誌。
- 日誌檔命名：`{任務名稱簡述}_{yyyyMMddHHmmss}.md`（例如 `記憶系統調整_20260625133552.md`）。
- 日誌內容簡述：任務範圍、主要變更、驗證結果、寫回的記憶重點。
- 同步更新 `Memories/logs/index.md`，維護最新任務清單與摘要。
- `logs/index.md` 在啟動時讀取最新前 10 筆（至多 3000 tokens），作為近期脈絡。

## 記憶策略

- `startup-index.json` 是每次任務的壓縮必讀索引，目標低於 1200 tokens，硬上限 1800 tokens。
- `preferences.json` 是穩定偏好的完整來源，不再每次必讀；只有索引不足、需要偏好細節或要改偏好時才讀。
- `agent-profile.json` 是高頻摘要快取；可被 `startup-index.json` 取代，或在需要更多背景時補讀。
- `projects/<project-key>/*.jsonl` 是專案級記憶，專案任務優先搜尋。
- `summaries.jsonl`、`project-facts.jsonl`、`decisions.jsonl` 先用 `rg` 搜尋，不整份塞入。
- 檢索結果先看任務相關度與狀態；相關度接近或規則衝突時，越近期的 active 記憶優先於較舊記憶。
- `raw` 只在摘要不足時讀。
- 不把無關專案記憶帶入當前任務。
- 長期使用時，active index 必須維持有界；舊摘要應封存、合併或標記取代，不讓每次任務前置 token 無限擴大。
- 前置總 token 預算硬上限 5000，超過時優先壓縮日誌 index 與 startup-index，不刪必要規則。

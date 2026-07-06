# Memories

這裡是 AI Agent Space 的長期記憶資料夾。

讀取順序建議：

1. `../AGENT_BOOTSTRAP.md`
2. 目前 repo 的 `AGENTS.md`
3. `index/startup-index.json`
4. 只有啟動索引不足、需要偏好細節或要修改記憶規則時，才讀 `index/agent-profile.json` 與 `index/preferences.json`
5. 依任務先搜尋 `projects/<project-key>/*.jsonl`
6. 用關鍵字搜尋 `index/*.jsonl`，通常只讀最相關 5 到 10 筆；相關度接近或規則衝突時，越近期的改動越優先
7. 任務需要時才讀 `../主要引導.md`、`../記憶系統規格.md`、`../DEVELOPMENT_PRINCIPLES.md` 或專案適配文件全文
8. 必要時才讀 `raw/**`

不要把全部 raw memory 一次讀入 prompt。先用摘要索引縮小範圍，再讀完整記憶。
也不要讓每次必讀檔案隨使用時間無限增加；固定前置內容應維持在短版啟動文件、repo `AGENTS.md` 與 `startup-index.json`。

修改記憶索引、schema、讀取規則或專案記憶後，執行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\s7514\Desktop\AI Agent Space\Memories\scripts\validate-memory.ps1"
```

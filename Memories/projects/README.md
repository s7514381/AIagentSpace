# Project Memories

這裡保存專案級長期記憶。當某個專案的 facts、decisions、warnings 或 bug fixes 增加時，優先寫到該專案自己的資料夾。

建議結構：

```text
projects/
  <project-key>/
    facts.jsonl
    decisions.jsonl
    warnings.jsonl
    bug-fixes.jsonl
```

`<project-key>` 使用穩定、可讀、無空白的名稱，例如 `SmartExpoIoT`。

專案任務的檢索優先順序：

1. 目前專案的 `projects/<project-key>/*.jsonl`
2. 全域 `index/decisions.jsonl`
3. 全域 `index/*.jsonl`
4. 必要時才讀 `raw/**`

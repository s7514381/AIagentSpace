# TaskStart Hook
# Read memory indexes, output contextModification for AI to get relevant memories
# Input: stdin JSON { task, mode, ... }
# Output: { cancel, contextModification, errorMessage }
# Optimized: v2 - Added unnamed task warning + duplicate work detection

$memoriesRoot = "C:\Users\s7514\source\repos\AIagentSpace\Memories"

try {
    $rawInput = $input | Out-String
    $inputObj = if ($rawInput) { $rawInput | ConvertFrom-Json } else { $null }
    
    $taskDescRaw = if ($inputObj -and $inputObj.task) { $inputObj.task } else { "" }
    $taskDesc = $taskDescRaw
    
    # Extract keywords from task description (English words only)
    $keywords = @()
    if ($taskDesc) {
        $matches = [regex]::Matches($taskDesc, '[A-Za-z][A-Za-z0-9]+')
        foreach ($m in $matches) {
            if ($m.Value.Length -ge 2) { $keywords += $m.Value }
        }
    }
    
    $keywords = $keywords | Select-Object -Unique | Select-Object -First 10
    
    # ---- UnnamedTask warning ----
    $unnamedWarning = ""
    if ([string]::IsNullOrWhiteSpace($taskDescRaw) -or $taskDescRaw -match "UnnamedTask") {
        $unnamedWarning = "[WARNING] 任務名稱為空或為 UnnamedTask，請提供有意義的任務名稱以確保記憶可追溯性。"
    }
    
    # ---- Duplicate work detection ----
    $dupWarnings = @()
    if ($taskDesc -and -not [string]::IsNullOrWhiteSpace($taskDesc) -and $keywords.Count -ge 2) {
        $searchTargets = @()
        $searchTargets += Join-Path $memoriesRoot "index\summaries.jsonl"
        $searchTargets += Join-Path $memoriesRoot "index\memory-index.jsonl"
        foreach ($st in $searchTargets) {
            if (Test-Path $st) {
                Get-Content $st -Encoding UTF8 | ForEach-Object {
                    $line = $_
                    if ($line.Trim()) {
                        try {
                            $entry = $line | ConvertFrom-Json
                            if ($entry.status -eq "archived" -or $entry.status -eq "purge_candidate") { return }
                            $entryText = @($entry.summary, $entry.keywords -join ' ', $entry.type, $entry.id) -join ' '
                            $matchCount = 0
                            foreach ($kw in $keywords) {
                                if ($entryText.ToLower().Contains($kw.ToLower())) { $matchCount++ }
                            }
                            if ($matchCount -ge 3 -or ($matchCount -ge 2 -and $keywords.Count -ge 2)) {
                                $dupWarnings += @{
                                    id = $entry.id
                                    type = $entry.type
                                    summary = $entry.summary
                                    createdAt = $entry.createdAt
                                    matchScore = $matchCount
                                }
                            }
                        } catch { }
                    }
                }
            }
        }
        $dupWarnings = $dupWarnings | Sort-Object matchScore -Descending | Select-Object -First 5
    }
    
    # Read startup-index.json
    $startupIndexPath = Join-Path $memoriesRoot "index\startup-index.json"
    $startupContent = ""
    if (Test-Path $startupIndexPath) {
        $startupContent = Get-Content $startupIndexPath -Raw -Encoding UTF8
    }
    
    # Read logs/index.md first 40 lines
    $logsIndexPath = Join-Path $memoriesRoot "logs\index.md"
    $logsContent = ""
    if (Test-Path $logsIndexPath) {
        $lines = Get-Content $logsIndexPath -Encoding UTF8
        $logsContent = ($lines | Select-Object -First 40) -join "`n"
    }
    
    # Search JSONL indexes
    $jsonlResults = @()
    $jsonlFiles = @()
    $jsonlFiles += Join-Path $memoriesRoot "index\summaries.jsonl"
    $jsonlFiles += Join-Path $memoriesRoot "index\decisions.jsonl"
    $jsonlFiles += Join-Path $memoriesRoot "index\project-facts.jsonl"

    
    $projectDirs = Get-ChildItem (Join-Path $memoriesRoot "projects") -Directory 2>$null
    foreach ($dir in $projectDirs) {
        $jsonlFiles += Get-ChildItem $dir.FullName -Filter "*.jsonl" | ForEach-Object { $_.FullName }
    }
    
    foreach ($file in $jsonlFiles) {
        if (Test-Path $file) {
            Get-Content $file -Encoding UTF8 | ForEach-Object {
                $line = $_
                if ($line.Trim()) {
                    try {
                        $entry = $line | ConvertFrom-Json
                        $matched = $false
                        
                        # Match against keywords
                        if ($entry.keywords -and $keywords.Count -gt 0) {
                            $entryKeywordsStr = ($entry.keywords | ForEach-Object { "$_".ToLower() }) -join " "
                            foreach ($kw in $keywords) {
                                if ($entryKeywordsStr.Contains($kw.ToLower())) {
                                    $matched = $true
                                    break
                                }
                            }
                        }
                        
                        # Match against summary
                        if (-not $matched -and $entry.summary -and $keywords.Count -gt 0) {
                            $summaryLower = $entry.summary.ToLower()
                            foreach ($kw in $keywords) {
                                if ($summaryLower.Contains($kw.ToLower())) {
                                    $matched = $true
                                    break
                                }
                            }
                        }
                        
                        # Match against project name
                        if (-not $matched -and $entry.project -and $taskDesc -and $taskDesc.Contains($entry.project)) {
                            $matched = $true
                        }
                        
                        if ($matched -and $entry.status -ne "archived" -and $entry.status -ne "purge_candidate") {
                            $jsonlResults += @{
                                id = $entry.id
                                type = $entry.type
                                summary = $entry.summary
                                importance = $entry.importance
                                keywords = $entry.keywords -join ", "
                                project = $entry.project
                                rawPath = $entry.rawPath
                            }
                        }
                    } catch {
                        # Skip malformed lines
                    }
                }
            }
        }
    }
    
    $jsonlResults = $jsonlResults | Sort-Object importance -Descending | Select-Object -First 8
    
    # Build contextModification
    $contextParts = @()
    $contextParts += "=== Memory System Startup Index ==="
    $contextParts += ""
    
    if ($unnamedWarning) {
        $contextParts += $unnamedWarning
        $contextParts += ""
    }
    
    if ($dupWarnings.Count -gt 0) {
        $contextParts += "[DUPLICATE WORK DETECTED — 可能的重複工作]"
        foreach ($dw in $dupWarnings) {
            $contextParts += "- [$($dw.type)] $($dw.summary) (created: $($dw.createdAt), matchScore: $($dw.matchScore))"
        }
        $contextParts += "[建議] 如果此任務與上述記錄重複，請考慮是否仍有必要重新執行。"
        $contextParts += ""
    }
    
    if ($keywords.Count -gt 0) {
        $contextParts += "[Task Keywords] $($keywords -join ', ')"
        $contextParts += ""
    }
    
    if ($jsonlResults.Count -gt 0) {
        $contextParts += "[Related Memory Summaries]"
        foreach ($r in $jsonlResults) {
            $rawHint = if ($r.rawPath) { " (full session: $($r.rawPath))" } else { "" }
            $contextParts += "- [$($r.type)] $($r.summary) (importance: $($r.importance))$rawHint"
        }
        $contextParts += ""
    }
    
    if ($logsContent) {
        $contextParts += "[Recent Task Logs (top 10)]"
        $contextParts += $logsContent
    }
    
    $contextModification = $contextParts -join "`n"
    
    @{
        cancel = $false
        contextModification = $contextModification
        errorMessage = ""
    } | ConvertTo-Json -Compress -Depth 10
    
} catch {
    @{
        cancel = $false
        contextModification = ""
        errorMessage = "[TaskStart Hook Error] $($_.Exception.Message)"
    } | ConvertTo-Json -Compress
}
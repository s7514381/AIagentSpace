# TaskStart Hook
# Read memory indexes, output contextModification for AI to get relevant memories
# Input: stdin JSON { task, mode, ... }
# Output: { cancel, contextModification, errorMessage }
# Optimized: v3 - Always inject startup memory + readId + bilingual keyword search

$memoriesRoot = "C:\Users\s7514\source\repos\AIagentSpace\Memories"
$dateStamp = Get-Date -Format "yyyyMMdd"
$readSuffix = -join ((48..57 + 65..90 + 97..122) | Get-Random -Count 5 | ForEach-Object { [char]$_ })
$readId = "read_${readSuffix}_$dateStamp"

function Add-UniqueKeyword {
    param(
        [System.Collections.ArrayList]$Target,
        [string]$Value
    )

    if (-not [string]::IsNullOrWhiteSpace($Value) -and $Value.Trim().Length -ge 2) {
        $trimmed = $Value.Trim()
        if (-not ($Target | Where-Object { $_.ToLower() -eq $trimmed.ToLower() })) {
            [void]$Target.Add($trimmed)
        }
    }
}

function Truncate-Text {
    param(
        [string]$Text,
        [int]$MaxChars = 6000
    )

    if ([string]::IsNullOrEmpty($Text)) { return "" }
    if ($Text.Length -le $MaxChars) { return $Text }
    return $Text.Substring(0, $MaxChars) + "`n...[truncated by TaskStart Hook]"
}

try {
    $rawInput = $input | Out-String
    $inputObj = if ($rawInput) { try { $rawInput | ConvertFrom-Json } catch { $null } } else { $null }
    
    $taskDescRaw = if ($inputObj -and $inputObj.task) { $inputObj.task } else { "" }
    $taskDesc = $taskDescRaw
    
    # Extract keywords from task description (English + Chinese phrases)
    $keywordList = [System.Collections.ArrayList]::new()
    if ($taskDesc) {
        $englishMatches = [regex]::Matches($taskDesc, '[A-Za-z][A-Za-z0-9]+')
        foreach ($m in $englishMatches) {
            Add-UniqueKeyword -Target $keywordList -Value $m.Value
        }

        $chineseMatches = [regex]::Matches($taskDesc, '[\u4e00-\u9fff]{2,}')
        foreach ($m in $chineseMatches) {
            Add-UniqueKeyword -Target $keywordList -Value $m.Value

            # Add short overlapping Chinese chunks to improve substring matching for long prompts.
            $text = $m.Value
            if ($text.Length -gt 4) {
                for ($i = 0; $i -le [Math]::Min($text.Length - 2, 8); $i += 2) {
                    $len = [Math]::Min(4, $text.Length - $i)
                    Add-UniqueKeyword -Target $keywordList -Value $text.Substring($i, $len)
                }
            }
        }
    }
    
    $keywords = @($keywordList | Select-Object -First 12)
    
    # ---- UnnamedTask warning ----
    $unnamedWarning = ""
    if ([string]::IsNullOrWhiteSpace($taskDescRaw) -or $taskDescRaw -match "UnnamedTask") {
        $unnamedWarning = "[WARNING] Task name is empty or UnnamedTask. Please provide a meaningful task name for traceable memory retrieval."
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
    
    # Read startup-index.json (mandatory compact startup memory)
    $startupIndexPath = Join-Path $memoriesRoot "index\startup-index.json"
    $startupContent = ""
    if (Test-Path $startupIndexPath) {
        $startupContent = Truncate-Text -Text (Get-Content $startupIndexPath -Raw -Encoding UTF8) -MaxChars 7000
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
    $jsonlFiles += Join-Path $memoriesRoot "index\memory-index.jsonl"
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
                        
                        # Match against summary / memoryName / type / project
                        if (-not $matched -and $entry.summary -and $keywords.Count -gt 0) {
                            $summaryLower = (@($entry.summary, $entry.memoryName, $entry.type, $entry.project) -join ' ').ToLower()
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

    # If keyword search has no hits (common for vague/Chinese prompts), still provide recent active memories.
    $recentFallback = @()
    if ($jsonlResults.Count -eq 0) {
        $fallbackFiles = @(
            (Join-Path $memoriesRoot "index\memory-index.jsonl"),
            (Join-Path $memoriesRoot "index\summaries.jsonl"),
            (Join-Path $memoriesRoot "index\decisions.jsonl")
        )
        foreach ($file in $fallbackFiles) {
            if (Test-Path $file) {
                Get-Content $file -Encoding UTF8 | Select-Object -Last 20 | ForEach-Object {
                    if ($_.Trim()) {
                        try {
                            $entry = $_ | ConvertFrom-Json
                            if ($entry.status -ne "archived" -and $entry.status -ne "purge_candidate") {
                                $recentFallback += @{
                                    id = $entry.id
                                    type = $entry.type
                                    summary = $entry.summary
                                    importance = $entry.importance
                                    createdAt = $entry.createdAt
                                    rawPath = $entry.rawPath
                                }
                            }
                        } catch { }
                    }
                }
            }
        }
        $recentFallback = $recentFallback | Sort-Object createdAt -Descending | Select-Object -First 5
    }
    
    # Build contextModification
    $contextParts = @()
    $contextParts += "=== Memory System Startup Index ==="
    $contextParts += "readId=$readId"
    $contextParts += "[Instruction] AI MUST mention this readId in the first response to confirm TaskStart memory was injected."
    $contextParts += ""

    if ($startupContent) {
        $contextParts += "[Startup Index]"
        $contextParts += $startupContent
        $contextParts += ""
    } else {
        $contextParts += "[WARNING] startup-index.json not found or empty."
        $contextParts += ""
    }
    
    if ($unnamedWarning) {
        $contextParts += $unnamedWarning
        $contextParts += ""
    }
    
    if ($dupWarnings.Count -gt 0) {
        $contextParts += "[DUPLICATE WORK DETECTED - possible repeated work]"
        foreach ($dw in $dupWarnings) {
            $contextParts += "- [$($dw.type)] $($dw.summary) (created: $($dw.createdAt), matchScore: $($dw.matchScore))"
        }
        $contextParts += "[Suggestion] If this task duplicates records above, consider whether rework is necessary."
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
    elseif ($recentFallback.Count -gt 0) {
        $contextParts += "[Recent Active Memories - fallback when no keyword match]"
        foreach ($r in $recentFallback) {
            $rawHint = if ($r.rawPath) { " (full session: $($r.rawPath))" } else { "" }
            $contextParts += "- [$($r.type)] $($r.summary) (created: $($r.createdAt), importance: $($r.importance))$rawHint"
        }
        $contextParts += ""
    }
    
    if ($logsContent) {
        $contextParts += "[Recent Task Logs (top 10)]"
        $contextParts += $logsContent
    }
    
    $contextModification = Truncate-Text -Text ($contextParts -join "`n") -MaxChars 16000
    
    $result = @{
        cancel = $false
        contextModification = $contextModification
        injectContext = $contextModification
        errorMessage = ""
    }

    $json = $result | ConvertTo-Json -Compress -Depth 10
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $stdout = [System.Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Close()
    
} catch {
    $errorResult = @{
        cancel = $false
        contextModification = ""
        injectContext = ""
        errorMessage = "[TaskStart Hook Error] $($_.Exception.Message)"
    }
    $json = $errorResult | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $stdout = [System.Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Close()
}
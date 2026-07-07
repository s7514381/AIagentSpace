# TaskStart Hook
# Read memory indexes, output contextModification for AI to get relevant memories
# Input: stdin JSON { task, mode, ... }
# Output: { cancel, contextModification, errorMessage }
# Optimized: v4 - startup memory + readId + bilingual keyword search + evidence snapshot + inbox policy

$agentSpace = "C:\Users\s7514\source\repos\AIagentSpace"
$memoriesRoot = "C:\Users\s7514\source\repos\AIagentSpace\Memories"
$runtimeDir = Join-Path $memoriesRoot "runtime"
$inboxDir = Join-Path $memoriesRoot "inbox"
$policyPath = Join-Path $memoriesRoot "config\consolidation-policy.json"
$dateStamp = Get-Date -Format "yyyyMMdd"
$readSuffix = -join ((48..57 + 65..90 + 97..122) | Get-Random -Count 5 | ForEach-Object { [char]$_ })
$readId = "read_${readSuffix}_$dateStamp"
$maxInjectTokens = 5000

if (-not (Test-Path -LiteralPath $runtimeDir)) { New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null }
if (-not (Test-Path -LiteralPath $inboxDir)) { New-Item -ItemType Directory -Path $inboxDir -Force | Out-Null }

function Invoke-GitText {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    try {
        $output = & git -C $agentSpace @Arguments 2>&1
        return [ordered]@{
            ok = ($LASTEXITCODE -eq 0)
            exitCode = $LASTEXITCODE
            text = (($output | ForEach-Object { "$_" }) -join "`n").Trim()
        }
    } catch {
        return [ordered]@{
            ok = $false
            exitCode = -1
            text = $_.Exception.Message
        }
    }
}

function Get-JsonObjectOrNull {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Get-InboxState {
    param([object]$Policy)

    $packets = @(Get-ChildItem -LiteralPath $inboxDir -File -Filter "*.json" -ErrorAction SilentlyContinue)
    $pendingPackets = @()
    foreach ($packet in $packets) {
        try {
            $json = Get-Content -LiteralPath $packet.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.status -eq "pending_review" -or -not $json.status) { $pendingPackets += $packet }
        } catch {
            $pendingPackets += $packet
        }
    }

    $pendingCount = $pendingPackets.Count
    $totalSizeKb = if ($pendingPackets.Count -gt 0) { [math]::Round((($pendingPackets | Measure-Object Length -Sum).Sum / 1KB), 2) } else { 0 }
    $oldest = if ($pendingPackets.Count -gt 0) { ($pendingPackets | Sort-Object LastWriteTime | Select-Object -First 1).LastWriteTime } else { $null }
    $oldestAgeDays = if ($oldest) { [math]::Round(((Get-Date) - $oldest).TotalDays, 2) } else { 0 }

    $silentBelow = 5
    $recommendAt = 10
    $strongAt = 20
    $oldestDays = 3
    $sizeKb = 500
    if ($Policy -and $Policy.memoryConsolidationPolicy) {
        if ($Policy.memoryConsolidationPolicy.silentBelowInboxCount) { $silentBelow = [int]$Policy.memoryConsolidationPolicy.silentBelowInboxCount }
        if ($Policy.memoryConsolidationPolicy.recommendAtInboxCount) { $recommendAt = [int]$Policy.memoryConsolidationPolicy.recommendAtInboxCount }
        if ($Policy.memoryConsolidationPolicy.stronglyRecommendAtInboxCount) { $strongAt = [int]$Policy.memoryConsolidationPolicy.stronglyRecommendAtInboxCount }
        if ($Policy.memoryConsolidationPolicy.recommendIfOldestDaysGreaterThan) { $oldestDays = [double]$Policy.memoryConsolidationPolicy.recommendIfOldestDaysGreaterThan }
        if ($Policy.memoryConsolidationPolicy.recommendIfInboxSizeKbGreaterThan) { $sizeKb = [double]$Policy.memoryConsolidationPolicy.recommendIfInboxSizeKbGreaterThan }
    }

    $level = "none"
    $reason = @()
    if ($pendingCount -ge $strongAt) { $level = "strong"; $reason += "pendingCount >= $strongAt" }
    elseif ($pendingCount -ge $recommendAt -or $oldestAgeDays -gt $oldestDays -or $totalSizeKb -gt $sizeKb) {
        $level = "recommended"
        if ($pendingCount -ge $recommendAt) { $reason += "pendingCount >= $recommendAt" }
        if ($oldestAgeDays -gt $oldestDays) { $reason += "oldestAgeDays > $oldestDays" }
        if ($totalSizeKb -gt $sizeKb) { $reason += "totalSizeKb > $sizeKb" }
    }
    elseif ($pendingCount -ge $silentBelow) { $level = "notice"; $reason += "pendingCount >= $silentBelow" }

    return [ordered]@{
        pendingCount = $pendingCount
        totalSizeKb = $totalSizeKb
        oldestPendingAt = if ($oldest) { $oldest.ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
        oldestAgeDays = $oldestAgeDays
        level = $level
        reasons = $reason
    }
}

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

function Get-ApproxTokenCount {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return 0 }

    # Lightweight tokenizer approximation for Hook budget control:
    # - CJK characters are often close to 1 token each.
    # - Non-CJK text is roughly 1 token per 4 non-whitespace chars.
    # This intentionally errs on the conservative side for mixed zh-TW/English context.
    $cjkCount = [regex]::Matches($Text, '[\u3400-\u9fff\uf900-\ufaff]').Count
    $nonCjkText = [regex]::Replace($Text, '[\u3400-\u9fff\uf900-\ufaff]', '')
    $nonWhitespaceCount = [regex]::Replace($nonCjkText, '\s+', '').Length

    return [int][math]::Ceiling($cjkCount + ($nonWhitespaceCount / 4.0))
}

function Limit-TextByApproxTokens {
    param(
        [string]$Text,
        [int]$MaxTokens = 5000
    )

    if ([string]::IsNullOrEmpty($Text)) { return "" }
    if ((Get-ApproxTokenCount -Text $Text) -le $MaxTokens) { return $Text }

    $suffix = "`n...[truncated by TaskStart Hook: approximate token budget ${MaxTokens}]"
    $targetTokens = [math]::Max(1, $MaxTokens - (Get-ApproxTokenCount -Text $suffix))
    $low = 0
    $high = $Text.Length
    $best = ""

    while ($low -le $high) {
        $mid = [int][math]::Floor(($low + $high) / 2)
        $candidate = $Text.Substring(0, $mid)
        if ((Get-ApproxTokenCount -Text $candidate) -le $targetTokens) {
            $best = $candidate
            $low = $mid + 1
        } else {
            $high = $mid - 1
        }
    }

    return $best + $suffix
}

function Test-LowInformationText {
    param(
        [string]$Text,
        [string]$TaskName = "",
        [double]$Importance = 0
    )

    $summary = if ($Text) { $Text.Trim() } else { "" }
    $task = if ($TaskName) { $TaskName.Trim() } else { "" }

    if ([string]::IsNullOrWhiteSpace($summary)) { return $true }
    if ($summary.Length -lt 8 -and $summary -match '^(OK|Done|Test|測試|完成|Task completed)$') { return $true }
    if ($summary -match '^(OK|Done|TestTask|Task completed|Completed)$') { return $true }
    if ($summary -match '^memoryName=memory_[A-Za-z0-9]+_\d{8}\s*$') { return $true }
    if ($summary -match '^Evidence packet written to Memories/inbox/') { return $true }
    if ($task -match '^(UnnamedTask|TestTask)\b' -and $Importance -lt 0.7) { return $true }

    return $false
}

function Get-UsefulLogsIndexExcerpt {
    param(
        [string]$Path,
        [int]$MaxRecentRows = 10,
        [int]$MaxOutputRows = 8
    )

    if (-not (Test-Path -LiteralPath $Path)) { return "" }

    $lines = Get-Content -LiteralPath $Path -Encoding UTF8
    $headerLines = @($lines | Select-Object -First 16)
    $rows = @()
    $inRecentTasks = $false

    foreach ($line in $lines) {
        if ($line -match '^##\s+Recent Tasks\s*$') {
            $inRecentTasks = $true
            continue
        }
        if ($inRecentTasks -and $line -match '^##\s+' -and $line -notmatch '^##\s+Recent Tasks\s*$') {
            break
        }
        if (-not $inRecentTasks) { continue }

        if ($line -match '^\|\s*\d+\s*\|') {
            $parts = $line -split '\|'
            if ($parts.Count -ge 6) {
                $taskName = $parts[3].Trim()
                $summary = $parts[5].Trim()
                if (-not (Test-LowInformationText -Text $summary -TaskName $taskName -Importance 0)) {
                    $rows += $line
                }
            }
        }

        if ($rows.Count -ge $MaxRecentRows) { break }
    }

    $rows = @($rows | Select-Object -First $MaxOutputRows)
    if ($rows.Count -eq 0) {
        return (($headerLines + @("", "[Recent Tasks omitted: no high-signal semantic summaries found in recent log rows.]")) -join "`n")
    }

    return (($headerLines + @("", "## Recent High-Signal Tasks", "", "| # | DateTime | Task Name | Log File | Summary |", "|---|----------|-----------|----------|---------|") + $rows) -join "`n")
}

try {
    $rawInput = $input | Out-String
    $inputObj = if ($rawInput) { try { $rawInput | ConvertFrom-Json } catch { $null } } else { $null }
    
    $taskDescRaw = if ($inputObj -and $inputObj.task) { $inputObj.task } else { "" }
    $taskDesc = $taskDescRaw

    # ---- Evidence snapshot for TaskComplete ----
    $policy = Get-JsonObjectOrNull -Path $policyPath
    $inboxState = Get-InboxState -Policy $policy
    $gitHead = Invoke-GitText -Arguments @("rev-parse", "HEAD")
    $gitBranch = Invoke-GitText -Arguments @("branch", "--show-current")
    $gitStatusShort = Invoke-GitText -Arguments @("status", "--short")

    $startSnapshot = [ordered]@{
        schemaVersion = 1
        startedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        readId = $readId
        workspace = $agentSpace
        taskPrompt = $taskDescRaw
        git = [ordered]@{
            head = $gitHead.text
            branch = $gitBranch.text
            statusShort = $gitStatusShort.text
            commandsOk = [ordered]@{
                head = $gitHead.ok
                branch = $gitBranch.ok
                status = $gitStatusShort.ok
            }
        }
        inbox = $inboxState
    }
    $startSnapshotPath = Join-Path $runtimeDir "current-task-start.json"
    $startSnapshot | ConvertTo-Json -Depth 20 | Out-File -FilePath $startSnapshotPath -Encoding UTF8
    
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
    
    # Read logs/index.md with low-information rows filtered out.
    $logsIndexPath = Join-Path $memoriesRoot "logs\index.md"
    $logsContent = ""
    if (Test-Path $logsIndexPath) {
        $logsContent = Get-UsefulLogsIndexExcerpt -Path $logsIndexPath -MaxRecentRows 12 -MaxOutputRows 8
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
                            $entryImportance = 0
                            if ($null -ne $entry.importance) { $entryImportance = [double]$entry.importance }
                            $entryTaskName = ""
                            if ($null -ne $entry.taskName) { $entryTaskName = [string]$entry.taskName }
                            if ($entry.status -ne "archived" -and $entry.status -ne "purge_candidate" -and -not (Test-LowInformationText -Text $entry.summary -TaskName $entryTaskName -Importance $entryImportance)) {
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
    $contextParts += "[Trace] readId is for hook/runtime diagnostics only. Do not require AI to mention it in responses."
    $contextParts += ""

    if ($startupContent) {
        $contextParts += "[Startup Index]"
        $contextParts += $startupContent
        $contextParts += ""
    } else {
        $contextParts += "[WARNING] startup-index.json not found or empty."
        $contextParts += ""
    }

    if ($inboxState.pendingCount -gt 0) {
        $contextParts += "[Memory Inbox State - not trusted memory]"
        $contextParts += "- pending packets: $($inboxState.pendingCount)"
        $contextParts += "- total size KB: $($inboxState.totalSizeKb)"
        $contextParts += "- oldest pending: $($inboxState.oldestPendingAt)"
        $contextParts += "- recommendation level: $($inboxState.level)"
        if ($inboxState.reasons.Count -gt 0) { $contextParts += "- reasons: $($inboxState.reasons -join ', ')" }
        if ($inboxState.level -eq "notice") {
            $contextParts += "[Notice] Pending inbox packets exist. No immediate action required unless task is memory-related."
        } elseif ($inboxState.level -eq "recommended") {
            $contextParts += "[CONSOLIDATION RECOMMENDED] Consider asking user to run Semantic Consolidation Task before relying on stale context."
        } elseif ($inboxState.level -eq "strong") {
            $contextParts += "[CONSOLIDATION STRONGLY RECOMMENDED] Ask user whether to consolidate Memories/inbox before continuing; context quality may degrade."
        }
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
    elseif ($jsonlResults.Count -eq 0) {
        $contextParts += "[Recent Active Memories]"
        $contextParts += "No high-signal fallback memories found. Low-information records such as OK/TestTask/UnnamedTask/evidence-packet-only summaries were omitted."
        $contextParts += ""
    }
    
    if ($logsContent) {
        $contextParts += "[Recent Task Logs - filtered for semantic signal]"
        $contextParts += $logsContent
    }
    
    $contextModification = Limit-TextByApproxTokens -Text ($contextParts -join "`n") -MaxTokens $maxInjectTokens
    
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
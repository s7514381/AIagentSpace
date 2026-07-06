# TaskComplete Hook
# Auto-save conversation memory, update indexes, write task log
# Input: stdin JSON { task, result, files, mode }
# Output: { cancel, contextModification, errorMessage }
# Optimized: v2 - Auto-naming for UnnamedTask, auto-validation, memoryName enforcement

$agentSpace = "C:\Users\s7514\source\repos\AIagentSpace"
$memoriesRoot = "$agentSpace\Memories"
$timestamp = Get-Date -Format "yyyyMMddHHmmss"
$dateStr = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$datePath = Get-Date -Format "yyyy/MM"
$rawDir = "$memoriesRoot\raw\$datePath"
$logsDir = "$memoriesRoot\logs"

if (-not (Test-Path $rawDir)) { New-Item -ItemType Directory -Path $rawDir -Force | Out-Null }

try {
    $rawInput = $input | Out-String
    $inputObj = if ($rawInput) { try { $rawInput | ConvertFrom-Json } catch { $null } } else { $null }
    
    # ---- Step 1: Extract task info with auto-naming for UnnamedTask ----
    $taskNameRaw = if ($inputObj -and $inputObj.task) { $inputObj.task } else { "" }
    $taskResult = if ($inputObj -and $inputObj.result) { $inputObj.result } else { "" }
    $taskFiles = if ($inputObj -and $inputObj.files) { $inputObj.files } else { @() }
    $taskMode = if ($inputObj -and $inputObj.mode) { $inputObj.mode } else { "" }
    
    # Auto-name if UnnamedTask or empty
    $taskName = $taskNameRaw
    if ([string]::IsNullOrWhiteSpace($taskName) -or $taskName -match "UnnamedTask") {
        $fallbackKeywords = @()
        if ($taskResult) {
            $kwMatches = [regex]::Matches($taskResult, '[A-Za-z][A-Za-z0-9]+')
            foreach ($m in $kwMatches) {
                if ($m.Value.Length -ge 2) { $fallbackKeywords += $m.Value }
            }
        }
        $fallbackKeywords = $fallbackKeywords | Select-Object -Unique | Select-Object -First 3
        if ($fallbackKeywords.Count -ge 2) {
            $taskName = $fallbackKeywords -join '_'
        } else {
            $taskName = "task_$timestamp"
        }
    }
    
    # Extract project hint from task name
    $projectHint = ""
    if ($taskName -match '(SmartExpoIoT|innoluxBenefit|Sixdots|ServiceBus|SunshineHeros)') {
        $projectHint = $matches[1]
    }
    
    # Generate memoryName in format: memory_xxxxx_YYYYMMDD
    $randomSuffix = -join ((65..90) + (97..122) | Get-Random -Count 5 | ForEach-Object { [char]$_ })
    $memId = "memory_${randomSuffix}_$(Get-Date -Format 'yyyyMMdd')"
    
    # ---- Step 2: Write raw memory ----
    $rawFileName = "$timestamp`_session.json"
    $rawFilePath = "$rawDir\$rawFileName"
    
    $rawMemory = @{
        id = $memId
        sessionId = "session-$timestamp"
        task = $taskName
        mode = $taskMode
        result = $taskResult
        files = $taskFiles
        project = $projectHint
        createdAt = $dateStr
        source = "TaskComplete Hook"
    }
    
    $rawMemory | ConvertTo-Json -Depth 10 -Compress | Out-File -FilePath $rawFilePath -Encoding UTF8
    
    # ---- Step 3: Determine importance and type ----
    $importance = 0.5
    $memType = "conversation"
    $keywords = @()
    
    if ($taskName) {
        $kwMatches = [regex]::Matches($taskName, '[A-Za-z][A-Za-z0-9]+')
        foreach ($m in $kwMatches) {
            if ($m.Value.Length -ge 2) { $keywords += $m.Value }
        }
    }
    if ($projectHint) { $keywords += $projectHint }
    $keywords = $keywords | Select-Object -Unique | Select-Object -First 8
    
    $fileCount = $taskFiles.Count
    if ($fileCount -ge 3) { $importance = 0.8 }
    elseif ($fileCount -ge 1) { $importance = 0.65 }
    
    $resultLower = $taskResult.ToLower()
    if ($resultLower -match 'build|error|bug|fix|hotfix|patch') { 
        $memType = "bug_fix"
        $importance = [Math]::Max($importance, 0.7)
    }
    elseif ($resultLower -match 'refactor|migrate|architecture|restruct') {
        $memType = "decision"
        $importance = [Math]::Max($importance, 0.75)
    }
    elseif ($resultLower -match 'prefer|style|format|convention') {
        $memType = "preference"
        $importance = [Math]::Max($importance, 0.7)
    }
    elseif ($resultLower -match 'caution|warning|avoid|careful') {
        $memType = "warning"
        $importance = [Math]::Max($importance, 0.7)
    }
    
    # ---- Step 4: Write to JSONL index ----
    $safeTaskName = $taskName -replace '[\\/:*?"<>|]', '_'
    $summaryEntry = @{
        id = $memId
        type = $memType
        createdAt = $dateStr
        keywords = $keywords
        summary = "[$taskName] $taskResult"
        importance = $importance
        status = "active"
        rawPath = "Memories/raw/$datePath/$rawFileName"
        taskLogPath = "Memories/logs/${safeTaskName}_$timestamp.md"
        project = $projectHint
    }
    
    if ($projectHint -and (Test-Path "$memoriesRoot\projects\$projectHint")) {
        $projectDir = "$memoriesRoot\projects\$projectHint"
        $jsonlTarget = switch ($memType) {
            "bug_fix" { "$projectDir\bug-fixes.jsonl" }
            "decision" { "$projectDir\decisions.jsonl" }
            "warning" { "$projectDir\warnings.jsonl" }
            "project_fact" { "$projectDir\facts.jsonl" }
            default { "$projectDir\facts.jsonl" }
        }
    } else {
        $jsonlTarget = switch ($memType) {
            "decision" { "$memoriesRoot\index\decisions.jsonl" }
            default { "$memoriesRoot\index\summaries.jsonl" }
        }
    }
    
    $summaryEntry | ConvertTo-Json -Depth 10 -Compress | Out-File -FilePath $jsonlTarget -Encoding UTF8 -Append
    
    # ---- Step 5: Write task log ----
    $logFileName = "${safeTaskName}_$timestamp.md"
    $logFilePath = "$logsDir\$logFileName"
    
    $fileList = ""
    foreach ($f in $taskFiles) { $fileList += "- $f`n" }
    
    $logContent = @"
# Task Log: $taskName

- **Date**: $dateStr
- **Mode**: $taskMode
- **Memory ID**: $memId
- **Raw Session**: $rawFilePath

## Scope & Goal

$taskName

## Changes

$fileList
## Result

$taskResult

## Memory Written

- Type: $memType
- Importance: $importance
- Keywords: $($keywords -join ', ')
- Index: $jsonlTarget
- memoryName: $memId
"@
    
    $logContent | Out-File -FilePath $logFilePath -Encoding UTF8
    
    # ---- Step 6: Update logs/index.md ----
    $indexPath = "$logsDir\index.md"
    $existingContent = ""
    $totalTasks = 0
    
    if (Test-Path $indexPath) {
        $existingContent = Get-Content $indexPath -Raw -Encoding UTF8
        
        if ($existingContent -match 'Total Tasks:\s*(\d+)') {
            $totalTasks = [int]$matches[1]
        }
    }
    
    $totalTasks++
    
    $summaryText = $taskResult -replace '\|', '/' -replace "`n", ' '
    if ($summaryText.Length -gt 100) { $summaryText = $summaryText.Substring(0, 100) + "..." }
    
    $now = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $newRow = "| $totalTasks | $now | $taskName | $logFileName | $summaryText |"
    
    # Build new index content
    $newIndex = @"
# Task Log Index

> **Rule: Always update this index when writing a log.**
> On each new log in 'logs/', sync this index:
> - Increment total task count
> - Add new row at top of 'Recent Tasks' table
> - Append row to 'Full List' section
> - Update 'Last Updated' time

> On startup, scan top 10 entries (max 3000 tokens) for recent context.
> Hard limit: 5000 tokens total (AGENT_BOOTSTRAP.md + startup-index.json + repo AGENTS.md + this index).

Total Tasks: $totalTasks
Last Updated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

---

## Recent Tasks

| # | DateTime | Task Name | Log File | Summary |
|---|----------|-----------|----------|---------|
"@
    
    # Parse existing rows
    $existingRows = @()
    $inRecentSection = $false
    $inFullListSection = $false
    $fullListRows = @()
    
    if ($existingContent) {
        $lines = $existingContent -split "`n"
        foreach ($line in $lines) {
            if ($line -match '^## Recent Tasks') { $inRecentSection = $true; $inFullListSection = $false; continue }
            if ($line -match '^## Full List') { $inRecentSection = $false; $inFullListSection = $true; continue }
            if ($line -match '^---') { continue }
            
            if ($inRecentSection -and $line -match '^\|') {
                if ($line -match '^\| # \|') { continue }
                if ($line -match '^\|---\|') { continue }
                $existingRows += $line
            }
            
            if ($inFullListSection -and $line -match '^\|') {
                if ($line -match '^\| # \|') { continue }
                if ($line -match '^\|---\|') { continue }
                $fullListRows += $line
            }
        }
    }
    
    $recentRows = @($newRow) + $existingRows | Select-Object -First 13
    $fullListRows += $newRow
    
    $newIndex += ($recentRows -join "`n")
    $newIndex += @"

---

## Full List

| # | DateTime | Task Name | Log File | Summary |
|---|----------|-----------|----------|---------|
"@
    $newIndex += "`n"
    $newIndex += ($fullListRows -join "`n")
    $newIndex += "`n"
    
    $newIndex | Out-File -FilePath $indexPath -Encoding UTF8
    
    # ---- Step 7: Auto-run validation ----
    $validationResult = ""
    $validateScript = "$agentSpace\Memories\scripts\validate-memory.ps1"
    if (Test-Path $validateScript) {
        try {
            $validationOutput = & $validateScript 2>&1
            $validationResult = $validationOutput | Out-String
        } catch {
            $validationResult = "[Validation Error] $($_.Exception.Message)"
        }
    }
    
    # ---- Step 8: Return summary with memoryName ----
    $contextModification = @"
[Memory Auto-Saved]
- Task: $taskName
- Memory ID: $memId
- Type: $memType
- Importance: $importance
- Keywords: $($keywords -join ', ')
- Raw Session: $rawFilePath
- Task Log: $logFilePath
- Index Updated: $jsonlTarget
- memoryName: $memId
"@
    
    if ($validationResult) {
        $contextModification += "`n[Validation Result]`n$validationResult"
    }
    
    @{
        cancel = $false
        contextModification = $contextModification
        errorMessage = ""
    } | ConvertTo-Json -Compress -Depth 10
    
} catch {
    @{
        cancel = $false
        contextModification = ""
        errorMessage = "[TaskComplete Hook Error] $($_.Exception.Message)"
    } | ConvertTo-Json -Compress
}
# TaskComplete Hook
# Auto-save conversation memory with forced memoryName validation
# Input: stdin JSON { task, result, files, mode }
# memoryName: AI MUST write to Memories/.memoryName file before attempt_completion
# Validation: REQUIRED from AI. If missing/invalid -> cancel=true + errorMessage -> AI must retry
# Output: { cancel, contextModification, errorMessage }

$agentSpace = "C:\Users\s7514\source\repos\AIagentSpace"
$memoriesRoot = "$agentSpace\Memories"
$memoryNameFile = "$memoriesRoot\.memoryName"
$pendingCompletionFile = "$memoriesRoot\.taskCompletePending.json"
$timestamp = Get-Date -Format "yyyyMMddHHmmss"
$dateStr = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$datePath = Get-Date -Format "yyyy/MM"
$rawDir = "$memoriesRoot\raw\$datePath"
$logsDir = "$memoriesRoot\logs"
$indexDir = "$memoriesRoot\index"

if (-not (Test-Path $rawDir)) { New-Item -ItemType Directory -Path $rawDir -Force | Out-Null }

function Reject-TaskComplete {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [object]$InputObject = $null
    )

    $pending = [ordered]@{
        rejectedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        code = $Code
        message = $Message
        requiredAction = "Write a valid memoryName to Memories/.memoryName, then retry attempt_completion. Format: memory_xxxxx_YYYYMMDD"
        example = "memory_HookA_$(Get-Date -Format 'yyyyMMdd')"
        task = if ($InputObject -and $InputObject.task) { $InputObject.task } else { "UnnamedTask" }
    }

    $pending | ConvertTo-Json -Compress -Depth 10 | Out-File -FilePath $pendingCompletionFile -Encoding UTF8

    $retryInstruction = "[TASK_COMPLETE_REJECTED][$Code] $Message Required action: before calling attempt_completion again, write a valid memoryName to 'Memories/.memoryName' using format 'memory_xxxxx_YYYYMMDD' (example: $($pending.example)). Then retry completion."

    [ordered]@{
        cancel = $true
        contextModification = $retryInstruction
        errorMessage = $retryInstruction
    } | ConvertTo-Json -Compress -Depth 10
    exit 0
}

try {
    $rawInput = $input | Out-String
    $inputObj = if ($rawInput) { try { $rawInput | ConvertFrom-Json } catch { $null } } else { $null }

    # ---- Step 0: Get memoryName ----
    # Priority 1: From .memoryName file (AI writes this before attempt_completion)
    # Priority 2: From stdin JSON memoryName field (if calling system passes it)
    # Priority 3: From result text (format: memoryName=memory_xxxxx_YYYYMMDD)
    $memoryName = ""
    $nameError = ""
    $memoryNameSource = ""

    # Priority 1: Read from .memoryName file
    if (Test-Path $memoryNameFile) {
        $fileContent = Get-Content $memoryNameFile -Raw -Encoding UTF8
        $memoryName = $fileContent.Trim()
        $memoryNameSource = "file"
        # Delete the file after reading (one-time use)
        Remove-Item $memoryNameFile -Force -ErrorAction SilentlyContinue
    }

    # Priority 2: From stdin JSON memoryName field
    if ([string]::IsNullOrEmpty($memoryName) -and $inputObj -and $inputObj.memoryName) {
        $memoryName = $inputObj.memoryName.Trim()
        $memoryNameSource = "stdin field"
    }

    # Priority 3: Extract from result text
    if ([string]::IsNullOrEmpty($memoryName) -and $inputObj -and $inputObj.result) {
        $resultText = $inputObj.result
        if ($resultText -match 'memoryName\s*[=:]\s*([A-Za-z0-9_]+)') {
            $memoryName = $matches[1].Trim()
            $memoryNameSource = "result text"
        }
    }

    # ---- Validate memoryName (REQUIRED) ----
    if ([string]::IsNullOrEmpty($memoryName)) {
        $nameError = "AI did not provide memoryName."
        Reject-TaskComplete -Code "MISSING_MEMORY_NAME" -Message $nameError -InputObject $inputObj
    }

    if ($memoryName -notmatch '^memory_') {
        $nameError = "Invalid memoryName prefix: '$memoryName'. Prefix must be 'memory_'."
        Reject-TaskComplete -Code "INVALID_MEMORY_NAME_PREFIX" -Message $nameError -InputObject $inputObj
    }

    if ($memoryName -notmatch '^memory_[A-Za-z0-9]+_\d{8}$') {
        $nameError = "Invalid memoryName format: '$memoryName'. Expected format: memory_xxxxx_YYYYMMDD (e.g., memory_abcde_20260706)."
        Reject-TaskComplete -Code "INVALID_MEMORY_NAME_FORMAT" -Message $nameError -InputObject $inputObj
    }

    # Valid memoryName received; clear any previous rejected-completion sentinel.
    Remove-Item $pendingCompletionFile -Force -ErrorAction SilentlyContinue

    # ---- Step 1: Extract task info ----
    $taskName = if ($inputObj -and $inputObj.task) { $inputObj.task } else { "UnnamedTask" }
    $taskResult = if ($inputObj -and $inputObj.result) { $inputObj.result } else { "" }
    $taskFiles = if ($inputObj -and $inputObj.files) { $inputObj.files } else { @() }
    $taskMode = if ($inputObj -and $inputObj.mode) { $inputObj.mode } else { "" }

    # Extract project hint from task name
    $projectHint = ""
    if ($taskName -match '(SmartExpoIoT|innoluxBenefit|Sixdots|ServiceBus|SunshineHeros)') {
        $projectHint = $matches[1]
    }

    $memId = "mem-$timestamp-$(Get-Random -Maximum 999)"

    # ---- Step 2: Write raw memory ----
    $rawFileName = "$timestamp`_session.json"
    $rawFilePath = "$rawDir\$rawFileName"

    $rawMemory = @{
        id = $memId
        memoryName = $memoryName
        sessionId = "session-$timestamp"
        task = $taskName
        mode = $taskMode
        result = $taskResult
        files = $taskFiles
        project = $projectHint
        createdAt = $dateStr
        source = "TaskComplete Hook"
        memoryNameSource = $memoryNameSource
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

    # ---- Step 4: Write to memory-index.jsonl (central index by memoryName) ----
    $memIndexPath = "$indexDir\memory-index.jsonl"
    $safeTaskName = $taskName -replace '[\\/:*?"<>|]', '_'

    $memIndexEntry = @{
        id = $memId
        memoryName = $memoryName
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

    $memIndexEntry | ConvertTo-Json -Depth 10 -Compress | Out-File -FilePath $memIndexPath -Encoding UTF8 -Append

    # ---- Step 5: Write to type-specific JSONL (existing behavior) ----
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
            "decision" { "$indexDir\decisions.jsonl" }
            default { "$indexDir\summaries.jsonl" }
        }
    }

    $summaryEntry = @{
        id = $memId
        memoryName = $memoryName
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

    $summaryEntry | ConvertTo-Json -Depth 10 -Compress | Out-File -FilePath $jsonlTarget -Encoding UTF8 -Append

    # ---- Step 6: Write task log ----
    $logFileName = "${safeTaskName}_$timestamp.md"
    $logFilePath = "$logsDir\$logFileName"

    $fileList = ""
    foreach ($f in $taskFiles) { $fileList += "- $f`n" }

    $logContent = @"
# Task Log: $taskName

- **Date**: $dateStr
- **Mode**: $taskMode
- **Memory Name**: $memoryName
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
- memoryIndex: $memIndexPath
- typeIndex: $jsonlTarget
"@

    $logContent | Out-File -FilePath $logFilePath -Encoding UTF8

    # ---- Step 7: Update logs/index.md ----
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

    # ---- Step 8: Return summary with memoryName confirmation ----
    $contextModification = @"
[Memory Saved - Confirmed by memoryName]
- memoryName: $memoryName (source: $memoryNameSource)
- Task: $taskName
- Memory ID: $memId
- Type: $memType
- Importance: $importance
- Keywords: $($keywords -join ', ')
- memory-index: $memIndexPath
- Raw Session: $rawFilePath
- Task Log: $logFilePath
"@

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
# TaskComplete Hook
# Evidence-first completion packet writer.
#
# This hook is intentionally non-semantic:
# - Collect observable evidence from git and TaskStart snapshot.
# - Store AI output only as an untrusted candidate.
# - Write pending review packets to Memories/inbox.
# - Do not directly promote stable memories.

$ErrorActionPreference = "Stop"

$agentSpace = "C:\Users\s7514\source\repos\AIagentSpace"
$memoriesRoot = Join-Path $agentSpace "Memories"
$runtimeDir = Join-Path $memoriesRoot "runtime"
$inboxDir = Join-Path $memoriesRoot "inbox"
$rawRoot = Join-Path $memoriesRoot "raw"
$logsDir = Join-Path $memoriesRoot "logs"

$timestamp = Get-Date -Format "yyyyMMddHHmmss"
$dateStr = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$datePath = Get-Date -Format "yyyy/MM"
$dateStamp = Get-Date -Format "yyyyMMdd"

foreach ($dir in @($runtimeDir, $inboxDir, $rawRoot, $logsDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

$rawDir = Join-Path $rawRoot $datePath
if (-not (Test-Path -LiteralPath $rawDir)) {
    New-Item -ItemType Directory -Path $rawDir -Force | Out-Null
}

function New-ShortId {
    param([int]$Length = 5)
    return -join ((48..57 + 65..90 + 97..122) | Get-Random -Count $Length | ForEach-Object { [char]$_ })
}

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

function Get-SafeFileName {
    param([string]$Text, [string]$Fallback = "UnnamedTask")
    $value = if ([string]::IsNullOrWhiteSpace($Text)) { $Fallback } else { $Text }
    $safe = $value -replace '[\\/:*?"<>|]', '_'
    if ($safe.Length -gt 80) { $safe = $safe.Substring(0, 80) }
    return $safe
}

function Update-TaskLogIndex {
    param([string]$TaskName, [string]$LogFileName, [string]$Summary)

    $indexPath = Join-Path $logsDir "index.md"
    $existingContent = ""
    $totalTasks = 0

    if (Test-Path -LiteralPath $indexPath) {
        $existingContent = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8
        if ($existingContent -match 'Total Tasks:\s*(\d+)') { $totalTasks = [int]$matches[1] }
    }

    $totalTasks++
    $summaryText = $Summary -replace '\|', '/' -replace "`r?`n", ' '
    if ($summaryText.Length -gt 100) { $summaryText = $summaryText.Substring(0, 100) + "..." }

    $newRow = "| $totalTasks | $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $TaskName | $LogFileName | $summaryText |"
    $existingRows = @()
    $fullListRows = @()
    $inRecentSection = $false
    $inFullListSection = $false

    if ($existingContent) {
        foreach ($line in ($existingContent -split "`n")) {
            if ($line -match '^## Recent Tasks') { $inRecentSection = $true; $inFullListSection = $false; continue }
            if ($line -match '^## Full List') { $inRecentSection = $false; $inFullListSection = $true; continue }
            if ($line -match '^---') { continue }

            if ($line -match '^\|' -and $line -notmatch '^\| # \|' -and $line -notmatch '^\|---') {
                if ($inRecentSection) { $existingRows += $line }
                if ($inFullListSection) { $fullListRows += $line }
            }
        }
    }

    $recentRows = @($newRow) + $existingRows | Select-Object -First 13
    $fullListRows += $newRow

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
$($recentRows -join "`n")

---

## Full List

| # | DateTime | Task Name | Log File | Summary |
|---|----------|-----------|----------|---------|
$($fullListRows -join "`n")
"@

    $newIndex | Out-File -FilePath $indexPath -Encoding UTF8
}

try {
    $rawInput = $input | Out-String
    $inputObj = if ($rawInput) { try { $rawInput | ConvertFrom-Json } catch { $null } } else { $null }

    $taskName = if ($inputObj -and $inputObj.task) { [string]$inputObj.task } else { "UnnamedTask" }
    $taskResult = if ($inputObj -and $inputObj.result) { [string]$inputObj.result } else { "" }
    $taskFiles = if ($inputObj -and $inputObj.files) { @($inputObj.files) } else { @() }
    $taskMode = if ($inputObj -and $inputObj.mode) { [string]$inputObj.mode } else { "" }

    $aiProvidedMemoryName = ""
    if ($inputObj -and $inputObj.memoryName) { $aiProvidedMemoryName = [string]$inputObj.memoryName }
    if ([string]::IsNullOrWhiteSpace($aiProvidedMemoryName) -and $taskResult -match 'memoryName\s*[=:]\s*([A-Za-z0-9_]+)') {
        $aiProvidedMemoryName = $matches[1]
    }

    $memoryName = "memory_$(New-ShortId -Length 5)_$dateStamp"
    $packetId = "packet_${timestamp}_$(New-ShortId -Length 5)"
    $sessionId = "session-$timestamp"
    $safeTaskName = Get-SafeFileName -Text $taskName

    $startSnapshotPath = Join-Path $runtimeDir "current-task-start.json"
    $startSnapshot = Get-JsonObjectOrNull -Path $startSnapshotPath

    $gitHeadAfter = Invoke-GitText -Arguments @("rev-parse", "HEAD")
    $gitBranch = Invoke-GitText -Arguments @("branch", "--show-current")
    $gitStatusShort = Invoke-GitText -Arguments @("status", "--short")
    $gitDiffStat = Invoke-GitText -Arguments @("diff", "--stat")
    $gitDiffNameOnly = Invoke-GitText -Arguments @("diff", "--name-only")
    $gitCachedStat = Invoke-GitText -Arguments @("diff", "--cached", "--stat")
    $gitCachedNameOnly = Invoke-GitText -Arguments @("diff", "--cached", "--name-only")

    $changedFiles = @()
    if ($gitDiffNameOnly.text) { $changedFiles += $gitDiffNameOnly.text -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } }
    if ($gitCachedNameOnly.text) { $changedFiles += $gitCachedNameOnly.text -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } }
    $changedFiles = @($changedFiles | Select-Object -Unique)

    $rawFileName = "$timestamp`_session.json"
    $rawFilePath = Join-Path $rawDir $rawFileName
    $rawRelativePath = "Memories/raw/$datePath/$rawFileName"
    $packetFileName = "${timestamp}_${packetId}.json"
    $packetPath = Join-Path $inboxDir $packetFileName
    $packetRelativePath = "Memories/inbox/$packetFileName"

    $resultPreview = $taskResult
    if ($resultPreview.Length -gt 1500) { $resultPreview = $resultPreview.Substring(0, 1500) + "...[truncated]" }

    $ruleTags = New-Object System.Collections.Generic.List[string]
    $ruleTags.Add("pending_review") | Out-Null
    # Keep hook source ASCII-only because Windows PowerShell 5 may parse UTF-8 without BOM as ANSI.
    if ($taskName -match 'memory|Hook|TaskComplete|TaskStart|context') { $ruleTags.Add("memory-system") | Out-Null }
    if ($changedFiles.Count -gt 0) { $ruleTags.Add("code-change-observed") | Out-Null } else { $ruleTags.Add("no-code-change-observed") | Out-Null }
    if ($gitDiffStat.text -match 'ps1|Hook|Memories') { $ruleTags.Add("hook-or-memory-file-change") | Out-Null }

    $rawSession = [ordered]@{
        schemaVersion = 1
        sessionId = $sessionId
        memoryName = $memoryName
        createdAt = $dateStr
        source = "TaskComplete Hook"
        trustModel = "ai_result_untrusted_observed_evidence_preferred"
        task = [ordered]@{ prompt = $taskName; mode = $taskMode; aiReportedFiles = $taskFiles }
        aiCandidate = [ordered]@{ result = $taskResult; aiProvidedMemoryName = $aiProvidedMemoryName; trusted = $false; status = "candidate" }
    }
    $rawSession | ConvertTo-Json -Depth 20 | Out-File -FilePath $rawFilePath -Encoding UTF8

    $packet = [ordered]@{
        schemaVersion = 1
        packetId = $packetId
        memoryName = $memoryName
        createdAt = $dateStr
        status = "pending_review"
        workspace = $agentSpace
        task = [ordered]@{
            prompt = $taskName
            mode = $taskMode
            startedAt = if ($startSnapshot -and $startSnapshot.startedAt) { $startSnapshot.startedAt } else { $null }
            completedAt = $dateStr
        }
        evidence = [ordered]@{
            level = "observed"
            sources = @("TaskStart snapshot", "git rev-parse HEAD", "git status --short", "git diff --stat", "git diff --name-only", "git diff --cached --stat", "git diff --cached --name-only")
            startSnapshotPath = if (Test-Path -LiteralPath $startSnapshotPath) { "Memories/runtime/current-task-start.json" } else { $null }
            git = [ordered]@{
                branch = $gitBranch.text
                headBefore = if ($startSnapshot -and $startSnapshot.git -and $startSnapshot.git.head) { $startSnapshot.git.head } else { $null }
                headAfter = $gitHeadAfter.text
                statusBefore = if ($startSnapshot -and $startSnapshot.git -and $startSnapshot.git.statusShort) { $startSnapshot.git.statusShort } else { $null }
                statusAfter = $gitStatusShort.text
                diffStat = $gitDiffStat.text
                changedFiles = $changedFiles
                cachedDiffStat = $gitCachedStat.text
                cachedChangedFiles = if ($gitCachedNameOnly.text) { @($gitCachedNameOnly.text -split "`n" | Where-Object { $_ }) } else { @() }
                commandsOk = [ordered]@{
                    head = $gitHeadAfter.ok; branch = $gitBranch.ok; status = $gitStatusShort.ok
                    diffStat = $gitDiffStat.ok; diffNameOnly = $gitDiffNameOnly.ok
                    cachedStat = $gitCachedStat.ok; cachedNameOnly = $gitCachedNameOnly.ok
                }
            }
        }
        aiCandidate = [ordered]@{
            resultPreview = $resultPreview
            aiReportedFiles = $taskFiles
            aiProvidedMemoryName = $aiProvidedMemoryName
            trusted = $false
            status = "candidate"
        }
        ruleBasedTags = @($ruleTags | Select-Object -Unique)
        review = [ordered]@{
            needsSemanticReview = $true
            recommendedAction = "evaluate_for_long_term_memory"
            reason = "TaskComplete Hook is non-semantic; promote only after semantic consolidation with evidence review."
        }
        rawPath = $rawRelativePath
    }
    $packet | ConvertTo-Json -Depth 20 | Out-File -FilePath $packetPath -Encoding UTF8

    $logFileName = "${safeTaskName}_$timestamp.md"
    $logFilePath = Join-Path $logsDir $logFileName
    $changedFileList = if ($changedFiles.Count -gt 0) { ($changedFiles | ForEach-Object { "- $_" }) -join "`n" } else { "- No changed files observed by git diff --name-only." }

    $logContent = @"
# Task Log: $taskName

- **Date**: $dateStr
- **Mode**: $taskMode
- **Memory Name**: $memoryName
- **Packet ID**: $packetId
- **Raw Session**: $rawRelativePath
- **Inbox Packet**: $packetRelativePath
- **Trust Model**: evidence-first; AI result is candidate/untrusted.

## Scope & Goal

$taskName

## Observed Evidence

- Git Branch: $($gitBranch.text)
- Git HEAD Before: $(if ($startSnapshot -and $startSnapshot.git -and $startSnapshot.git.head) { $startSnapshot.git.head } else { "unknown" })
- Git HEAD After: $($gitHeadAfter.text)

### Changed Files

$changedFileList

### Git Diff Stat

```text
$($gitDiffStat.text)
```

## AI Candidate Result Preview

> This content is untrusted until semantic consolidation reviews evidence.

```text
$resultPreview
```

## Memory Packet

- Status: pending_review
- Review Required: true
- Packet: $packetRelativePath
"@

    $logContent | Out-File -FilePath $logFilePath -Encoding UTF8
    Update-TaskLogIndex -TaskName $taskName -LogFileName $logFileName -Summary "Evidence packet written to $packetRelativePath; semantic review required."

    $contextModification = @"
[Evidence Packet Saved]
- memoryName: $memoryName (generated by hook)
- packetId: $packetId
- status: pending_review
- inboxPacket: $packetRelativePath
- rawSession: $rawRelativePath
- changedFilesObserved: $($changedFiles.Count)
- trustModel: AI result stored as untrusted candidate; stable memory requires Semantic Consolidation Task.
"@

    [ordered]@{ cancel = $false; contextModification = $contextModification; errorMessage = "" } | ConvertTo-Json -Compress -Depth 10
} catch {
    [ordered]@{ cancel = $false; contextModification = ""; errorMessage = "[TaskComplete Hook Error] $($_.Exception.Message)" } | ConvertTo-Json -Compress -Depth 10
}
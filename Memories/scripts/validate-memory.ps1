param(
  [string]$AgentSpaceRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

$ErrorActionPreference = "Stop"

$validStatuses = @(
  "active",
  "superseded",
  "unverified",
  "archived",
  "purge_candidate"
)

$parseErrors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Add-ParseError([string]$message) {
  $parseErrors.Add($message) | Out-Null
}

function Add-Warning([string]$message) {
  $warnings.Add($message) | Out-Null
}

function Test-MemoryRecord {
  param(
    [object]$Record,
    [string]$Source
  )

  foreach ($field in @("id", "type", "status", "summary", "importance")) {
    if (-not $Record.PSObject.Properties.Name.Contains($field)) {
      Add-Warning "$Source missing field: $field"
    }
  }

  if ($Record.PSObject.Properties.Name.Contains("status")) {
    if ($validStatuses -notcontains [string]$Record.status) {
      Add-ParseError "$Source invalid status: $($Record.status)"
    }
  }

  if ($Record.PSObject.Properties.Name.Contains("importance")) {
    $importance = 0.0
    if (-not [double]::TryParse([string]$Record.importance, [ref]$importance)) {
      Add-ParseError "$Source importance is not numeric: $($Record.importance)"
    } elseif ($importance -lt 0 -or $importance -gt 1) {
      Add-ParseError "$Source importance out of range: $importance"
    }
  }

  if ($Record.PSObject.Properties.Name.Contains("status") -and
      [string]$Record.status -eq "active" -and
      $Record.PSObject.Properties.Name.Contains("summary")) {
    $summary = [string]$Record.summary
    $oldMandatoryPreferenceRead =
      $summary -match "\u6bcf\u6b21\u4efb\u52d9\u5148\u8b80.*preferences" -or
      $summary -match "\u6bcf\u6b21\u804a\u5929\u958b\u59cb.*preferences" -or
      $summary -match "\u5148\u8b80 bootstrap\u3001repo AGENTS\u3001preferences" -or
      $summary -match "\u518d\u8b80 Memories/index/preferences" -or
      $summary -match "agent-profile\.json\u3001preferences\.json"

    if ($oldMandatoryPreferenceRead) {
      Add-ParseError "$Source active record still mentions old mandatory preferences/profile startup read"
    }
  }
}

if (-not (Test-Path -LiteralPath $AgentSpaceRoot)) {
  throw "AgentSpaceRoot not found: $AgentSpaceRoot"
}

$memoryRoot = Join-Path $AgentSpaceRoot "Memories"
if (-not (Test-Path -LiteralPath $memoryRoot)) {
  throw "Memories folder not found: $memoryRoot"
}

$jsonCount = 0
Get-ChildItem -LiteralPath $AgentSpaceRoot -Recurse -File -Filter "*.json" | ForEach-Object {
  $relative = $_.FullName.Substring($AgentSpaceRoot.Length + 1)
  try {
    Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
    $jsonCount++
  } catch {
    Add-ParseError "$relative JSON parse failed: $($_.Exception.Message)"
  }
}

$jsonlCount = 0
$recordCount = 0
Get-ChildItem -LiteralPath $AgentSpaceRoot -Recurse -File -Filter "*.jsonl" | ForEach-Object {
  $file = $_
  $relative = $file.FullName.Substring($AgentSpaceRoot.Length + 1)
  $lineNo = 0
  $jsonlCount++

  Get-Content -LiteralPath $file.FullName -Encoding UTF8 | ForEach-Object {
    $lineNo++
    if ([string]::IsNullOrWhiteSpace($_)) {
      return
    }

    try {
      $record = $_ | ConvertFrom-Json
      $recordCount++
      Test-MemoryRecord -Record $record -Source "${relative}:$lineNo"
    } catch {
      Add-ParseError "${relative}:$lineNo JSONL parse failed: $($_.Exception.Message)"
    }
  }
}

$preferencesPath = Join-Path $memoryRoot "index\preferences.json"
if (Test-Path -LiteralPath $preferencesPath) {
  $preferences = Get-Content -LiteralPath $preferencesPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $index = 0
  foreach ($preference in $preferences.preferences) {
    $index++
    Test-MemoryRecord -Record $preference -Source "Memories\index\preferences.json:preferences[$index]"
  }
}

$startupIndexPath = Join-Path $memoryRoot "index\startup-index.json"
if (Test-Path -LiteralPath $startupIndexPath) {
  $startupIndex = Get-Content -LiteralPath $startupIndexPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($startupIndex.PSObject.Properties.Name.Contains("tokenBudget")) {
    $hardMax = [int]$startupIndex.tokenBudget.hardMaxTokens
    $charCount = (Get-Content -LiteralPath $startupIndexPath -Raw -Encoding UTF8).Length
    $roughTokens = [math]::Ceiling($charCount / 2.0)
    if ($hardMax -gt 0 -and $roughTokens -gt $hardMax) {
      Add-Warning "startup-index rough token estimate $roughTokens exceeds hardMaxTokens $hardMax"
    }
  }

  if (-not $startupIndex.PSObject.Properties.Name.Contains("retrievalOrdering")) {
    Add-Warning "startup-index missing retrievalOrdering"
  }
}

$memoryRulesPath = Join-Path $memoryRoot "config\memory-rules.json"
if (Test-Path -LiteralPath $memoryRulesPath) {
  $memoryRules = Get-Content -LiteralPath $memoryRulesPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not $memoryRules.retrieval.PSObject.Properties.Name.Contains("preferRecentChanges") -or
      $memoryRules.retrieval.preferRecentChanges -ne $true) {
    Add-Warning "memory-rules retrieval.preferRecentChanges is not true"
  }

  if (-not $memoryRules.retrieval.PSObject.Properties.Name.Contains("recencyDateFields")) {
    Add-Warning "memory-rules retrieval.recencyDateFields is missing"
  }
}

Write-Output "JSON files: $jsonCount"
Write-Output "JSONL files: $jsonlCount"
Write-Output "JSONL records: $recordCount"
Write-Output "Warnings: $($warnings.Count)"
foreach ($warning in $warnings) {
  Write-Output "WARN $warning"
}

if ($parseErrors.Count -gt 0) {
  Write-Output "Errors: $($parseErrors.Count)"
  foreach ($errorItem in $parseErrors) {
    Write-Output "ERROR $errorItem"
  }
  exit 1
}

Write-Output "Memory validation passed."

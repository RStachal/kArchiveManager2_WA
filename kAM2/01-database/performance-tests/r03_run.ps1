<#
.SYNOPSIS
  R-03 performance-benchmark runner for kArchiveManager 2.0.

.DESCRIPTION
  Installs the harness (idempotent) and runs ONE benchmarked scenario via sqlcmd
  (Windows auth), then writes the per-run report to publish/. Run on an
  OTHERWISE-IDLE instance (isolation requirement — see docs/v2-performance-benchmark.md).

.EXAMPLE
  ./r03_run.ps1 -ServerInstance "RADIM-STACHAL\RSTSQL2022" -ProcessCode RF_LOG2 -SourceDb Edge -ScaleLabel large -MaxCandidates 1000000 -Strategy TIMESTAMP -CheapMode

.NOTES
  Permissions: the connecting login needs VIEW SERVER STATE, ALTER ANY EVENT SESSION,
  and EXECUTE on the runner chain (benchmark/operator context, not the least-priv runtime).
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $ServerInstance,
  [string] $AdminDb       = 'kArchiveManagerAdmin',
  [Parameter(Mandatory)] [string] $ProcessCode,
  [Parameter(Mandatory)] [string] $SourceDb,
  [string] $ArchiveDb     = 'kArchiveManagerBackups',
  [string] $ScaleLabel    = 'large',
  [ValidateSet('ANCHOR','TIMESTAMP','MIXED')] [string] $Strategy = 'TIMESTAMP',
  [switch] $CheapMode,
  [int]    $MaxCandidates = 1000000,
  [int]    $StopMinutes   = 180,
  [switch] $DryRun,
  [switch] $SkipInstall
)
$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$harness = Join-Path $here 'r03_benchmark_harness.sql'
$repoRoot = Resolve-Path (Join-Path $here '..\..')
$outDir = Join-Path $repoRoot 'publish'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$outFile = Join-Path $outDir "r03_benchmark_${ProcessCode}_${SourceDb}_${ScaleLabel}_$stamp.txt"

$sqlcmd = (Get-Command sqlcmd -ErrorAction SilentlyContinue)
if (-not $sqlcmd) { throw "sqlcmd not found on PATH." }

function Invoke-Sql([string]$InputFile, [string]$Query, [string]$Out) {
  $args = @('-S', $ServerInstance, '-d', $AdminDb, '-E', '-b', '-l', '30', '-w', '4000', '-W')
  if ($InputFile) { $args += @('-i', $InputFile) } else { $args += @('-Q', $Query) }
  if ($Out) { $args += @('-o', $Out) }
  & $sqlcmd.Source @args
  if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed (exit $LASTEXITCODE) for $($InputFile + $Query)" }
}

if (-not $SkipInstall) {
  Write-Host "Installing benchmark harness..." -ForegroundColor Cyan
  Invoke-Sql -InputFile $harness
}

$cheap  = if ($CheapMode) { 1 } else { 0 }
$dry    = if ($DryRun)    { 1 } else { 0 }
$label  = "$Strategy $ProcessCode@$SourceDb $ScaleLabel" + $(if ($CheapMode) {' cheap'} else {''})

$q = @"
SET NOCOUNT ON;
EXEC bench.usp_RunBenchmark
     @ProcessCode = N'$ProcessCode', @SourceDb = N'$SourceDb', @ArchiveDb = N'$ArchiveDb',
     @Label = N'$label', @ScaleLabel = N'$ScaleLabel', @Strategy = N'$Strategy', @CheapMode = $cheap,
     @MaxCandidates = $MaxCandidates, @StopMinutes = $StopMinutes, @DryRun = $dry;
PRINT '=== REPORT ===';
EXEC bench.usp_BenchmarkReport @Top = 10;
"@

Write-Host "Running benchmark: $label ..." -ForegroundColor Cyan
Invoke-Sql -Query $q -Out $outFile
Write-Host "Done. Report: $outFile" -ForegroundColor Green
Get-Content $outFile | Select-Object -Last 40

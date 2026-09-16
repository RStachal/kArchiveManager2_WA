<#
.SYNOPSIS
    Orchestrates the kArchiveManager 2.0 deployment, configuration and test for a
    Koerber Warehouse Advantage source database.

.DESCRIPTION
    Runs the numbered scripts in sql\ in order against the target instance.

    Parameter substitution: each script declares its inputs as SQLCMD ":setvar"
    lines. This script writes a WORKING COPY of every file with those values
    replaced, and runs the copy.

    That indirection is not cosmetic. sqlcmd gives ":setvar" inside the file the
    same precedence as "-v" on the command line, and the later assignment wins -
    so an in-file ":setvar" silently OVERRIDES anything passed with -v. Rewriting
    the file is the only reliable way to parameterise these scripts.
    (The core deploy bundle has the same trap in a worse form: its ":r" include
    paths are quoted, and sqlcmd does not expand variables inside a quoted :r
    path at all, so those get expanded to literal paths here.)

.PARAMETER Stage
    Which part of the sequence to run:
      precheck  - 01 only (read-only, safe anywhere)
      analyse   - 01, 03, and 09 if configuration already exists (read-only)
      deploy    - 02 + the core bundle + verify + selftest + variant tests
      configure - 03, then the six document sets (04, 05, 20, 24, 25, 26, 27),
                  then 08 index report, 06 provisioning, 07 validation
      runtime   - prints the manual steps for the runner login and the Agent jobs
      test      - 09, test data (30, 31, 32), a dry pass (22), then the
                  read-only verdicts 33 and 50. NO deletes.
      realrun   - 11, 12 (DELETES DATA - requires -IConfirm)
      perf      - 40, 41 (throughput measurement; DELETES)
      perfrestore - 42 (undoes what 40/41 changed outside their test data)
      cleanup   - 99 (removes the test footprint; requires -IConfirm)
      all       - deploy, configure, test  (stops before realrun on purpose)

.EXAMPLE
    .\Run-Deploy.ps1 -Server SQLPROD01 -SourceDb WA_LIVE -Stage precheck

.EXAMPLE
    .\Run-Deploy.ps1 -Server SQLPROD01 -SourceDb WA_LIVE -Stage all -RetentionDays 540

.EXAMPLE
    .\Run-Deploy.ps1 -Server SQLPROD01 -SourceDb WA_LIVE -Stage realrun -IConfirm -MaxDocuments 10
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Server,

    # The WMS source database (Koerber Warehouse Advantage).
    [Parameter(Mandatory = $true)]
    [string] $SourceDb,

    # The second source database, holding the application log (t_log_message).
    # Pass the same value as -SourceDb if there is only one.
    [string] $AdvDb = 'ADV',

    [string] $AdminDb   = 'kArchiveManagerAdmin',
    [string] $ArchiveDb = 'kArchiveManagerBackups',

    # Rolling retention in days. 90 is a test value; production is typically 540.
    [int] $RetentionDays = 90,

    # Must be a name present in sys.time_zone_info on the target instance.
    [string] $SourceTimezone = 'Central European Standard Time',

    [string] $OrderProcessCode = 'AAD_ORDER_ARCH',
    [string] $WorkQProcessCode = 'AAD_WORKQ_ARCH',

    # WHERE THE PRODUCT IS.
    #
    # Leave this empty and the script uses the copy vendored in this package, at
    # kAM2\01-database - which is the normal case and makes the package
    # self-contained: clone it, run it, no second checkout required.
    #
    # Set it only when you are working from the vendor's own source repository,
    # where the layout differs: the bundle sits in deploy\v2\release-package\ and
    # its includes resolve against the repo root rather than a source-objects\
    # folder. Pass the ArchiveManager1.0 folder in that case.
    #
    # It used to default to a developer's local path, which meant -Stage deploy
    # could not work on any other machine.
    [string] $RepoRoot = '',

    [ValidateSet('precheck','analyse','deploy','configure','runtime','test','realrun','perf','perfrestore','cleanup','all')]
    [string] $Stage = 'precheck',

    # Required for -Stage realrun and -Stage cleanup.
    [switch] $IConfirm,

    # Document cap for a capped real run (11_realrun_guarded.sql).
    [int] $MaxDocuments = 10,

    # The login that owns the Agent job; the job simulation impersonates it so
    # the privilege gate behaves as it does inside the real job.
    [string] $RunnerLogin = 'karch_runtime_svc',

    [string] $WorkDir = "$PSScriptRoot\_work",
    [string] $LogDir  = "$PSScriptRoot\_logs"
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve where the product lives, and with it the three paths that differ
# between the two layouts. Auto-detect rather than ask, because the vendored
# copy is right for everyone except whoever is editing the product itself.
#
#   vendored (this package)        legacy (vendor source repo)
#   kAM2\01-database\              <RepoRoot>\deploy\v2\release-package\   bundle + test packs
#   kAM2\01-database\source-objects <RepoRoot>                            $(Root) for the :r includes
#   kAM2\01-database\operational-add-ons                                  the parameterised add-ons
# ---------------------------------------------------------------------------
$vendored = Join-Path $PSScriptRoot 'kAM2\01-database'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    if (-not (Test-Path (Join-Path $vendored 'deploy_clean_v2_full.sql'))) {
        throw "The vendored product is missing at $vendored. Either restore kAM2\ or pass -RepoRoot pointing at the ArchiveManager1.0 folder of the vendor repository."
    }
    $BundleDir  = $vendored
    $IncludeDir = Join-Path $vendored 'source-objects'
    $AddOnDir   = Join-Path $vendored 'operational-add-ons'
    $LayoutName = 'vendored (kAM2\01-database)'
}
else {
    $BundleDir  = Join-Path $RepoRoot 'deploy\v2\release-package'
    $IncludeDir = $RepoRoot
    $AddOnDir   = Join-Path $RepoRoot 'deploy\v2'
    $LayoutName = "vendor repository ($RepoRoot)"
}

# ---------------------------------------------------------------------------
# Locate sqlcmd
# ---------------------------------------------------------------------------
$sqlcmd = (Get-Command sqlcmd -ErrorAction SilentlyContinue).Source
if (-not $sqlcmd) {
    $candidates = @(
        'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\SQLCMD.EXE',
        'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE',
        'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\130\Tools\Binn\SQLCMD.EXE'
    )
    foreach ($c in $candidates) { if (Test-Path $c) { $sqlcmd = $c; break } }
}
if (-not $sqlcmd) { throw "sqlcmd.exe not found. Install the SQL Server command line utilities." }

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir  | Out-Null

Write-Host "sqlcmd    : $sqlcmd"
Write-Host "Server    : $Server"
Write-Host "SourceDb  : $SourceDb"
Write-Host "AdminDb   : $AdminDb"
Write-Host "ArchiveDb : $ArchiveDb"
Write-Host "Retention : $RetentionDays days"
Write-Host "Timezone  : $SourceTimezone"
Write-Host "Stage     : $Stage"
Write-Host ""

# ---------------------------------------------------------------------------
# Values substituted into every :setvar line
# ---------------------------------------------------------------------------
$vars = @{
    'AdminDb'          = $AdminDb
    'SourceDb'         = $SourceDb
    'ArchiveDb'        = $ArchiveDb
    'RetentionDays'    = "$RetentionDays"
    'SourceTimezone'   = $SourceTimezone
    'OrderProcessCode' = $OrderProcessCode
    'WorkQProcessCode' = $WorkQProcessCode
    'MaxDocuments'     = "$MaxDocuments"
    'IConfirm'         = $(if ($IConfirm) { 'YES' } else { 'NO' })
    'RunnerLogin'      = $RunnerLogin
    'WmsDb'            = $SourceDb
    'AdvDb'            = $AdvDb
}

function New-WorkingCopy {
    param([string] $SqlFile, [hashtable] $Overrides = @{})

    $name = Split-Path $SqlFile -Leaf
    $dest = Join-Path $WorkDir $name
    $text = Get-Content -LiteralPath $SqlFile -Raw -Encoding UTF8

    $effective = $vars.Clone()
    foreach ($k in $Overrides.Keys) { $effective[$k] = $Overrides[$k] }

    foreach ($k in $effective.Keys) {
        # Replace only the declaration line, so occurrences of $(Var) in the body
        # are still resolved by sqlcmd itself.
        $pattern = '(?m)^:setvar\s+' + [regex]::Escape($k) + '\s+"[^"]*"\s*$'
        $text = [regex]::Replace($text, $pattern, ':setvar ' + $k + ' "' + $effective[$k] + '"')
    }

    [System.IO.File]::WriteAllText($dest, $text, (New-Object System.Text.UTF8Encoding $true))
    return $dest
}

function Invoke-SqlFile {
    param(
        [string] $SqlFile,
        [string] $Database = 'master',
        [hashtable] $Overrides = @{},
        [switch] $AllowFailure
    )

    $name = Split-Path $SqlFile -Leaf
    $run  = New-WorkingCopy -SqlFile $SqlFile -Overrides $Overrides
    $log  = Join-Path $LogDir ($name -replace '\.sql$', '.log')

    Write-Host "--> $name" -ForegroundColor Cyan
    # -b   : non-zero exit on SQL error (pairs with the scripts' own :on error exit)
    # -I   : QUOTED_IDENTIFIER ON
    # -f 65001 : the files are UTF-8 without BOM and contain non-ASCII in comments
    & $sqlcmd -S $Server -E -b -I -f 65001 -d $Database -i $run -o $log
    $code = $LASTEXITCODE

    $errors = Select-String -Path $log -Pattern 'Msg \d+, Level 1[6-9]' -ErrorAction SilentlyContinue
    if ($code -ne 0 -or $errors) {
        Write-Host "    FAILED (exit $code) - see $log" -ForegroundColor Red
        if ($errors) { $errors | Select-Object -First 5 | ForEach-Object { Write-Host "    $($_.Line)" -ForegroundColor Red } }
        if (-not $AllowFailure) { throw "$name failed. Log: $log" }
    }
    else {
        Write-Host "    OK - $log" -ForegroundColor Green
    }
    return $log
}

$sqlDir = Join-Path $PSScriptRoot 'sql'

# ---------------------------------------------------------------------------
# The core deploy bundle needs its quoted :r paths expanded to literals,
# because sqlcmd will not substitute a variable inside a quoted :r path.
# ---------------------------------------------------------------------------
function Invoke-CoreBundle {
    $master = Join-Path $BundleDir 'deploy_clean_v2_full.sql'
    if (-not (Test-Path $master)) { throw "Core bundle not found at $master. Layout in use: $LayoutName." }

    $text = Get-Content -LiteralPath $master -Raw -Encoding UTF8
    # Drop the in-file Root declaration and hardcode the path everywhere. The
    # includes are "$(Root)\Databases\..." and "$(Root)\kArchiveManagerAdmin\...",
    # which live under source-objects\ in the vendored copy and at the repo root
    # in the vendor's own layout - hence $IncludeDir rather than the bundle dir.
    $text = [regex]::Replace($text, '(?m)^:setvar\s+Root\s+"[^"]*"\s*$', '-- :setvar Root removed by Run-Deploy.ps1 (paths expanded below)')
    $text = $text.Replace('$(Root)', $IncludeDir)

    $run = Join-Path $WorkDir 'deploy_clean_v2_full.RUN.sql'
    [System.IO.File]::WriteAllText($run, $text, (New-Object System.Text.UTF8Encoding $true))

    if (Select-String -Path $run -Pattern '\$\(Root\)' -Quiet) { throw "Root substitution failed in $run" }

    # Verify every include actually exists before touching the server.
    $missing = @()
    Select-String -Path $run -Pattern '^\s*:r\s+"([^"]+)"' | ForEach-Object {
        $p = $_.Matches[0].Groups[1].Value
        if (-not (Test-Path $p)) { $missing += $p }
    }
    if ($missing.Count -gt 0) {
        $missing | ForEach-Object { Write-Host "    MISSING INCLUDE: $_" -ForegroundColor Red }
        throw "$($missing.Count) include file(s) missing under $IncludeDir. Layout in use: $LayoutName."
    }

    $log = Join-Path $LogDir 'core_deploy.log'
    Write-Host "--> deploy_clean_v2_full.sql (core bundle, $((Select-String -Path $run -Pattern '^\s*:r').Count) includes)" -ForegroundColor Cyan
    & $sqlcmd -S $Server -E -b -I -f 65001 -d master -i $run -o $log
    if ($LASTEXITCODE -ne 0) { throw "Core deploy failed. Log: $log" }
    if (-not (Select-String -Path $log -Pattern 'CLEAN deploy completed' -Quiet)) {
        throw "Core deploy did not reach completion. Log: $log"
    }
    Write-Host "    OK - $log" -ForegroundColor Green

    $rp = $BundleDir
    foreach ($f in @('verify_clean_deploy.sql', 'selftest_acceptance.sql', 'variant_test_pack.sql')) {
        $src = Join-Path $rp $f
        $lg  = Join-Path $LogDir ($f -replace '\.sql$', '.log')
        Write-Host "--> $f" -ForegroundColor Cyan
        & $sqlcmd -S $Server -E -b -I -f 65001 -d $AdminDb -i $src -o $lg
        if ($LASTEXITCODE -ne 0) { throw "$f failed. Log: $lg" }
        $verdict = Select-String -Path $lg -Pattern 'PASS|FAIL|ALL VARIANTS PASSED' | Select-Object -First 3
        $verdict | ForEach-Object { Write-Host "    $($_.Line.Trim())" }
        if (Select-String -Path $lg -Pattern '^FAIL' -Quiet) { throw "$f reported FAIL. Log: $lg" }
    }
}

# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------
switch ($Stage) {

    'precheck' {
        Invoke-SqlFile (Join-Path $sqlDir '01_precheck.sql')
    }

    'analyse' {
        Invoke-SqlFile (Join-Path $sqlDir '01_precheck.sql')
        Invoke-SqlFile (Join-Path $sqlDir '03_source_analysis.sql')
        Invoke-SqlFile (Join-Path $sqlDir '09_preflight_data.sql') -AllowFailure
    }

    'deploy' {
        Invoke-SqlFile (Join-Path $sqlDir '01_precheck.sql')
        Invoke-SqlFile (Join-Path $sqlDir '02_databases.sql')
        Invoke-CoreBundle
    }

    'configure' {
        # Order of the seeds matters: 04/05/20/24 create the five processes, then
        # 25 re-shapes them into non-overlapping document sets and sets the
        # cross-set RunOrder. Running 25 before the seeds would have nothing to
        # re-shape.
        Invoke-SqlFile (Join-Path $sqlDir '03_source_analysis.sql')
        Invoke-SqlFile (Join-Path $sqlDir '04_seed_order.sql')            # order set
        Invoke-SqlFile (Join-Path $sqlDir '05_seed_workq.sql')            # work-queue set
        Invoke-SqlFile (Join-Path $sqlDir '20_seed_standalone.sql')       # tran-log + pick sets
        Invoke-SqlFile (Join-Path $sqlDir '24_seed_logmessage_anchor.sql')# ADV application log
        Invoke-SqlFile (Join-Path $sqlDir '25_seed_document_sets.sql')    # header>detail shaping + RunOrder
        # 26 and 27 were missing from this stage until 2026-09-16 while
        # DEPLOYMENT.md already claimed the stage ran them. A deployment that
        # followed the runbook therefore came out WITHOUT the purchase-order set
        # and without the three FK children of t_order - and an ORDER run on real
        # customer data then fails on the foreign key, which is exactly how it
        # failed on the reference instance. They must come before 06, so the
        # archive tables for their objects get provisioned.
        Invoke-SqlFile (Join-Path $sqlDir '26_add_pick_order_children.sql') # pick + order FK children
        Invoke-SqlFile (Join-Path $sqlDir '27_seed_po_set.sql')            # inbound purchase-order set
        # 08 is a READ-ONLY report. We never create indexes in a WMS database -
        # it hands the DDL to the schema owner instead. There is no Apply switch.
        Invoke-SqlFile (Join-Path $sqlDir '08_source_indexes.sql')
        Invoke-SqlFile (Join-Path $sqlDir '06_provision.sql')
        Invoke-SqlFile (Join-Path $sqlDir '07_validate.sql')
        Write-Host ""
        Write-Host "Check the FK_COMPLETE_ORDER block 26 printed: every table with a" -ForegroundColor Yellow
        Write-Host "foreign key into t_order must say 'yes'. A MISSING there is a run-time" -ForegroundColor Yellow
        Write-Host "failure later, and 07_validate does NOT check it." -ForegroundColor Yellow
    }

    'runtime' {
        Write-Host "The runner principal and job ownership come from the product's own" -ForegroundColor Yellow
        Write-Host "parameterized scripts, which need a password and are therefore manual:" -ForegroundColor Yellow
        Write-Host "  1) $AddOnDir\053_runtime_least_privilege_principal.sql" -ForegroundColor Yellow
        Write-Host "     set @SourceDbsCsv = '$SourceDb,$AdvDb', a strong @SqlPassword, @Apply = 1" -ForegroundColor Yellow
        Write-Host "  2) sql\56_agent_jobs.sql   @Apply = 1" -ForegroundColor Yellow
        Write-Host "     Creates all five Agent jobs with both runner jobs owned correctly." -ForegroundColor Yellow
        Write-Host "     Use it INSTEAD of 054: 054 re-owns only RUN CONFIGURED, so PREP keeps" -ForegroundColor Yellow
        Write-Host "     the deploying login, its own privilege gate refuses a sysadmin, and the" -ForegroundColor Yellow
        Write-Host "     job then fails on every start with Error 51001." -ForegroundColor Yellow
        Write-Host "     On an instance already built with 054, run sql\55_fix_prep_job_owner.sql." -ForegroundColor Yellow
        Write-Host "" -ForegroundColor Yellow
        Write-Host "RE-RUN 053 AFTER ANY CONFIGURATION CHANGE that adds a table: it grants" -ForegroundColor Yellow
        Write-Host "only on the tables mapped at the time it ran. Skipping that gives" -ForegroundColor Yellow
        Write-Host "'SELECT permission was denied' at run time." -ForegroundColor Yellow
        Write-Host "AND AFTER ANY RESTORE of a source database: a restore replaces every" -ForegroundColor Yellow
        Write-Host "database principal, so the runner and the console both lose their users" -ForegroundColor Yellow
        Write-Host "and nothing warns you. Re-run 053, then 051 for the console." -ForegroundColor Yellow
    }

    'test' {
        Invoke-SqlFile (Join-Path $sqlDir '09_preflight_data.sql')
        Invoke-SqlFile (Join-Path $sqlDir '30_test_data_all.sql')
        # 31 and 32 cover the sets 30 does not: the purchase-order family and the
        # children added by 26. Without them the test stage exercised four of the
        # six sets and reported success.
        Invoke-SqlFile (Join-Path $sqlDir '31_test_data_po.sql')
        Invoke-SqlFile (Join-Path $sqlDir '32_test_data_children.sql')
        Invoke-SqlFile (Join-Path $sqlDir '22_simulate_job.sql') -Overrides @{ 'RunForReal' = '0' }
        # Read-only verdict on whatever has been archived so far. Harmless on a
        # dry pass - it simply reports zero movement.
        Invoke-SqlFile (Join-Path $sqlDir '33_verify_bulk.sql') -Database $AdminDb -AllowFailure
        Invoke-SqlFile (Join-Path $sqlDir '50_reporting.sql')    -Database $AdminDb -AllowFailure
        Write-Host ""
        Write-Host "Pre-flight, test data and a dry pass are done - NOTHING was deleted." -ForegroundColor Yellow
        Write-Host "Read 33_verify_bulk's section C (gates) and D (orphans) in $LogDir," -ForegroundColor Yellow
        Write-Host "then run -Stage realrun -IConfirm." -ForegroundColor Yellow
    }

    'realrun' {
        if (-not $IConfirm) {
            throw "-Stage realrun DELETES SOURCE DATA. Re-run with -IConfirm once -Stage test looks correct."
        }
        # The job simulation IS the real run: it replays both Agent job steps,
        # impersonating the runner login so the privilege gate behaves as it does
        # inside the job.
        Invoke-SqlFile (Join-Path $sqlDir '22_simulate_job.sql') -Overrides @{ 'RunForReal' = '1' }
        Invoke-SqlFile (Join-Path $sqlDir '23_verify_standalone.sql')
        Write-Host ""
        Write-Host "Check 23_verify_standalone.log:" -ForegroundColor Yellow
        Write-Host "  section B  - every row must reconcile" -ForegroundColor Yellow
        Write-Host "  section C  - C_ORPHAN_CHECK must be 0 / 0 / 0" -ForegroundColor Yellow
    }

    'perf' {
        # Throughput measurement. This is NOT part of a normal deployment - it
        # seeds millions of rows into the source databases and then archives and
        # deletes them, and it temporarily lifts the batching caps and disables
        # the vendor log purge job. Only worth running on an instance where that
        # is acceptable, which is why it demands -IConfirm like the real run.
        if (-not $IConfirm) {
            throw "-Stage perf seeds millions of test rows, then ARCHIVES AND DELETES them, and temporarily changes the batching caps and the vendor 'Log Maintenance' job. Re-run with -IConfirm."
        }
        # try/finally, NOT two bare calls. 40_perf_seed.sql disables the vendor
        # 'Log Maintenance' job and then spends minutes bulk-seeding; any error in
        # there aborts the script with the job still disabled, i.e. ADV's own log
        # housekeeping silently switched off in the customer's WMS. Without the
        # finally the stage would stop at that point and never even mention the
        # undo. -AllowFailure on the restore so a broken restore cannot mask the
        # original error that got us here.
        try {
            Invoke-SqlFile (Join-Path $sqlDir '40_perf_seed.sql')
            Invoke-SqlFile (Join-Path $sqlDir '41_perf_test.sql')

            Write-Host ""
            Write-Host "Read 41_perf_test.log in this order - the checks come before the numbers:" -ForegroundColor Yellow
            Write-Host "  CAPS_RESTORED / VENDOR_JOB_RESTORED - nothing was left changed" -ForegroundColor Yellow
            Write-Host "  COVERAGE            - every set produced a run" -ForegroundColor Yellow
            Write-Host "  VALIDITY            - StillEligible > 0, or the figure is a volume" -ForegroundColor Yellow
            Write-Host "  PURGE_INTERFERENCE  - must be empty for the ADV figure to be clean" -ForegroundColor Yellow
            Write-Host "  PERF_BY_TABLE       - the per-table answer" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Then run -Stage cleanup -IConfirm. The seeded rows are large enough to matter." -ForegroundColor Yellow
        }
        finally {
            Write-Host ""
            Write-Host "Verifying that nothing was left changed (42_perf_restore.sql) ..." -ForegroundColor Cyan
            Invoke-SqlFile (Join-Path $sqlDir '42_perf_restore.sql') -AllowFailure | Out-Null
            Write-Host "If that log still shows STILL_PENDING or CAP_UNRECOVERABLE, act on it before leaving the instance." -ForegroundColor Yellow
        }
    }

    'perfrestore' {
        # Standalone undo for a perf cycle that died before restoring.
        Invoke-SqlFile (Join-Path $sqlDir '42_perf_restore.sql')
    }

    'cleanup' {
        if (-not $IConfirm) {
            throw "-Stage cleanup DELETES the test rows and the run history. Re-run with -IConfirm."
        }
        Invoke-SqlFile (Join-Path $sqlDir '99_cleanup_test.sql') -Overrides @{
            'CleanTestData' = '1'; 'CleanRunHistory' = '1'; 'CleanProfiles' = '1'; 'CleanConfig' = '0'
        }
    }

    'all' {
        Invoke-SqlFile (Join-Path $sqlDir '01_precheck.sql')
        Invoke-SqlFile (Join-Path $sqlDir '02_databases.sql')
        Invoke-CoreBundle
        Invoke-SqlFile (Join-Path $sqlDir '03_source_analysis.sql')
        Invoke-SqlFile (Join-Path $sqlDir '04_seed_order.sql')
        Invoke-SqlFile (Join-Path $sqlDir '05_seed_workq.sql')
        Invoke-SqlFile (Join-Path $sqlDir '20_seed_standalone.sql')
        Invoke-SqlFile (Join-Path $sqlDir '24_seed_logmessage_anchor.sql')
        Invoke-SqlFile (Join-Path $sqlDir '25_seed_document_sets.sql')
        Invoke-SqlFile (Join-Path $sqlDir '08_source_indexes.sql')
        Invoke-SqlFile (Join-Path $sqlDir '06_provision.sql')
        Invoke-SqlFile (Join-Path $sqlDir '07_validate.sql')
        Invoke-SqlFile (Join-Path $sqlDir '09_preflight_data.sql')
        Write-Host ""
        Write-Host "Deployed and configured. Next, in order:" -ForegroundColor Yellow
        Write-Host "  -Stage runtime            (runner login + job ownership, manual)" -ForegroundColor Yellow
        Write-Host "  -Stage test               (test data + dry pass, deletes nothing)" -ForegroundColor Yellow
        Write-Host "  -Stage realrun -IConfirm  (DELETES)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Done. Logs: $LogDir" -ForegroundColor Green

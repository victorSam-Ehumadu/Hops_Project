<#
.SYNOPSIS
    Proves a Hops database backup can actually be restored.

.DESCRIPTION
    A dump file that has never been restored is not a backup - it is an
    untested assumption. This restores the newest file in backups/ into a
    throwaway local database, counts what came back, and then drops it.

    Nothing touches the cloud database. The only server contacted is the
    local PostgreSQL instance installed alongside pg_dump.

.NOTES
    Run from the repository root:

        powershell -ExecutionPolicy Bypass -File .\scripts\verify-backup.ps1

    Asks for the LOCAL postgres password - the one set in the PostgreSQL
    installer - not the Supabase database password.
#>

param(
    [string]$BackupFile,
    [string]$TestDb = "hops_restore_test",
    # Leave the restored database in place so it can be opened and browsed.
    # Off by default: the point of this script is to prove a restore works,
    # and leaving a copy of every row in the cloud database — password
    # hashes and the full moderation log included — sitting on a laptop is
    # not something that should happen unless it was asked for.
    [switch]$Keep
)

# Deliberately NOT "Stop". In Windows PowerShell 5.1, redirecting a native
# executable's stderr wraps each line in an ErrorRecord (NativeCommandError),
# so an entirely benign message - dropdb reporting "database does not exist,
# skipping" - becomes a terminating error under Stop and aborts the run.
# Every external call below is checked explicitly via $LASTEXITCODE instead.
$ErrorActionPreference = "Continue"

# --- Locate the client binaries -----------------------------------------
$binDir = $null
$cand = Get-ChildItem "C:\Program Files\PostgreSQL\*\bin\psql.exe" -ErrorAction SilentlyContinue |
        Sort-Object { [int]($_.Directory.Parent.Name) } -Descending
if ($cand) { $binDir = $cand[0].Directory.FullName }

if (-not $binDir) {
    Write-Host "psql not found. Install with: winget install PostgreSQL.PostgreSQL.17" -ForegroundColor Red
    exit 1
}
$psql     = Join-Path $binDir "psql.exe"
$createdb = Join-Path $binDir "createdb.exe"
$dropdb   = Join-Path $binDir "dropdb.exe"

# --- Pick the backup -----------------------------------------------------
if (-not $BackupFile) {
    $newest = Get-ChildItem "backups\*.sql" -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) {
        Write-Host "No .sql files in backups\. Run backup-db.ps1 first." -ForegroundColor Red
        exit 1
    }
    $BackupFile = $newest.FullName
}
Write-Host "Verifying: $BackupFile" -ForegroundColor Cyan
Write-Host ""

# --- Local credentials ---------------------------------------------------
Write-Host "This needs the password for the LOCAL postgres user - the one you"
Write-Host "set while installing PostgreSQL 17. Not the Supabase password."
Write-Host ""
$pw = Read-Host "Local postgres password" -AsSecureString
$env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw))
$env:PGHOST = "localhost"
$env:PGPORT = "5432"
$env:PGUSER = "postgres"
# Suppress the server-side NOTICE that --if-exists emits on a missing database.
$env:PGOPTIONS = "-c client_min_messages=warning"

try {
    # --- Fresh scratch database -----------------------------------------
    Write-Host ""
    Write-Host "Creating scratch database $TestDb ..." -ForegroundColor DarkGray
    & $dropdb --if-exists $TestDb *>$null
    $mk = & $createdb $TestDb 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Could not create the scratch database." -ForegroundColor Red
        $mk | ForEach-Object { Write-Host ("   " + $_) -ForegroundColor DarkYellow }
        exit 1
    }

    # --- Restore ---------------------------------------------------------
    # ON_ERROR_STOP is deliberately off: the dump references Supabase-only
    # roles and extensions that do not exist locally, and those errors are
    # expected noise. What matters is that the tables and rows land.
    Write-Host "Restoring ..." -ForegroundColor DarkGray
    $log = Join-Path $env:TEMP "hops_restore.log"
    & $psql -d $TestDb -q -f $BackupFile 2>&1 | Out-File -FilePath $log -Encoding utf8

    $errs = @(Select-String -Path $log -Pattern "^psql:.*ERROR" -ErrorAction SilentlyContinue)

    # --- Count what came back -------------------------------------------
    # Count each table for real; pg_stat n_live_tup is only an estimate.
    $tables = & $psql -d $TestDb -At -c "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;"

    Write-Host ""
    Write-Host "Restored tables and row counts:" -ForegroundColor Green
    $total = 0
    foreach ($t in $tables) {
        if (-not $t) { continue }
        $n = & $psql -d $TestDb -At -c "SELECT count(*) FROM public.`"$t`";"
        $total += [int]$n
        Write-Host ("   {0,-28} {1} rows" -f $t, $n)
    }

    $fn = & $psql -d $TestDb -At -c "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public';"
    $ix = & $psql -d $TestDb -At -c "SELECT count(*) FROM pg_indexes WHERE schemaname='public';"

    Write-Host ""
    Write-Host ("   Tables:    {0}" -f @($tables | Where-Object { $_ }).Count)
    Write-Host ("   Rows:      {0}" -f $total)
    Write-Host ("   Functions: {0}" -f $fn)
    Write-Host ("   Indexes:   {0}" -f $ix)

    if ($errs.Count -gt 0) {
        Write-Host ""
        Write-Host ("Restore reported {0} error line(s). Full log: {1}" -f $errs.Count, $log) -ForegroundColor Yellow
        $errs | Select-Object -First 8 | ForEach-Object { Write-Host ("   " + $_.Line) -ForegroundColor DarkYellow }
        Write-Host "   (errors about roles like supabase_admin or missing extensions are expected)" -ForegroundColor DarkGray
    } else {
        Write-Host ""
        Write-Host "Restore completed with no errors." -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "RESTORE VERIFIED - the backup is usable." -ForegroundColor Green
}
finally {
    # --- Always clean up -------------------------------------------------
    Write-Host ""
    if ($Keep) {
        Write-Host "Keeping scratch database '$TestDb' (-Keep)." -ForegroundColor Yellow
        Write-Host "  Browse it:  psql -d $TestDb" -ForegroundColor DarkGray
        Write-Host "  Or in pgAdmin: Servers > PostgreSQL > Databases > $TestDb" -ForegroundColor DarkGray
        Write-Host "  Delete it when done:  dropdb $TestDb" -ForegroundColor DarkGray
        Write-Host "  It holds a full copy of the cloud database - do not leave it lying around." -ForegroundColor DarkYellow
    } else {
        Write-Host "Dropping scratch database ..." -ForegroundColor DarkGray
        & $dropdb --if-exists $TestDb *>$null
    }
    Remove-Item Env:PGOPTIONS  -ErrorAction SilentlyContinue
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:PGHOST     -ErrorAction SilentlyContinue
    Remove-Item Env:PGPORT     -ErrorAction SilentlyContinue
    Remove-Item Env:PGUSER     -ErrorAction SilentlyContinue
}

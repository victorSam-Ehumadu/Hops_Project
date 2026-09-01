<#
.SYNOPSIS
    Resets the password of the LOCAL postgres superuser.

.DESCRIPTION
    For the case where the password set during the PostgreSQL installer is
    no longer known. Nothing here touches the Supabase database - the only
    server involved is the local instance on this machine.

    The method is the standard one: PostgreSQL cannot be asked to reveal a
    password, but it can be told to stop checking. pg_hba.conf is switched
    from scram-sha-256 to trust on loopback only, the service is restarted,
    a new password is set, and then the original file is put back.

    The original pg_hba.conf is copied aside before anything is changed,
    and restored in a finally block so an error mid-run cannot leave the
    server accepting unauthenticated local connections. The backup path is
    printed up front so it can be restored by hand if this process is
    killed outright.

.NOTES
    Must be run from an ELEVATED PowerShell (Run as administrator) - the
    data directory and the service are both protected.

        powershell -ExecutionPolicy Bypass -File .\scripts\reset-local-pg-password.ps1
#>

$ErrorActionPreference = "Stop"

# --- Elevation check -----------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "This script must run as administrator." -ForegroundColor Red
    Write-Host ""
    Write-Host "Press the Windows key, type: powershell"
    Write-Host "Right-click 'Windows PowerShell' and choose 'Run as administrator'."
    Write-Host "Then:"
    Write-Host "    cd C:\Projects\Hops_Project"
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\scripts\reset-local-pg-password.ps1"
    exit 1
}

# --- Locate the installation --------------------------------------------
$pgRoot = Get-ChildItem "C:\Program Files\PostgreSQL\*" -Directory -ErrorAction SilentlyContinue |
          Sort-Object { [int]$_.Name } -Descending | Select-Object -First 1
if (-not $pgRoot) {
    Write-Host "No PostgreSQL installation found." -ForegroundColor Red
    exit 1
}

$hba  = Join-Path $pgRoot.FullName "data\pg_hba.conf"
$psql = Join-Path $pgRoot.FullName "bin\psql.exe"

if (-not (Test-Path $hba))  { Write-Host "pg_hba.conf not found at $hba" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $psql)) { Write-Host "psql not found at $psql"       -ForegroundColor Red; exit 1 }

$svc = Get-Service -Name "postgresql*" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $svc) {
    Write-Host "No PostgreSQL service found." -ForegroundColor Red
    exit 1
}

Write-Host "PostgreSQL: $($pgRoot.FullName)" -ForegroundColor DarkGray
Write-Host "Service:    $($svc.Name)"        -ForegroundColor DarkGray
Write-Host ""

# --- Collect the new password before changing anything -------------------
# Asking first keeps the window in which authentication is disabled as
# short as possible.
$p1 = Read-Host "New password for the local postgres user" -AsSecureString
$p2 = Read-Host "Confirm it"                                -AsSecureString

$s1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1))
$s2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2))

if ($s1 -ne $s2) {
    Write-Host "Those did not match. Nothing has been changed." -ForegroundColor Red
    exit 1
}
if ([string]::IsNullOrWhiteSpace($s1)) {
    Write-Host "Empty password refused. Nothing has been changed." -ForegroundColor Red
    exit 1
}

# --- Back up pg_hba.conf -------------------------------------------------
$stamp  = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = "$hba.hops-backup-$stamp"
Copy-Item $hba $backup

Write-Host ""
Write-Host "Original pg_hba.conf saved to:" -ForegroundColor Yellow
Write-Host "   $backup" -ForegroundColor Yellow
Write-Host "If this script is interrupted, copy that file back over pg_hba.conf" -ForegroundColor Yellow
Write-Host "and restart the $($svc.Name) service." -ForegroundColor Yellow
Write-Host ""

try {
    # --- Disable authentication on loopback only -------------------------
    # Only the three loopback rules are touched. Nothing is opened to any
    # other host, because no other host is listed in this file.
    $orig = Get-Content $hba
    $trusted = $orig | ForEach-Object { $_ -replace "scram-sha-256", "trust" }
    Set-Content -Path $hba -Value $trusted -Encoding ascii

    Write-Host "Restarting $($svc.Name) with authentication temporarily off ..." -ForegroundColor DarkGray
    Restart-Service -Name $svc.Name -Force
    Start-Sleep -Seconds 3

    # --- Set the new password --------------------------------------------
    # Written to a temporary file rather than passed with -c: a command
    # line is visible to any process listing while it runs.
    $escaped = $s1 -replace "'", "''"
    $sqlFile = Join-Path $env:TEMP "hops_pwreset_$stamp.sql"
    Set-Content -Path $sqlFile -Value "ALTER USER postgres WITH PASSWORD '$escaped';" -Encoding ascii

    $env:PGHOST = "localhost"; $env:PGPORT = "5432"; $env:PGUSER = "postgres"
    & $psql -d postgres -q -f $sqlFile
    $code = $LASTEXITCODE

    Remove-Item $sqlFile -Force -ErrorAction SilentlyContinue

    if ($code -ne 0) {
        Write-Host "Failed to set the password (psql exit $code)." -ForegroundColor Red
    } else {
        Write-Host "Password set." -ForegroundColor Green
    }
}
finally {
    # --- Always put authentication back ----------------------------------
    Write-Host ""
    Write-Host "Restoring pg_hba.conf ..." -ForegroundColor DarkGray
    Copy-Item $backup $hba -Force
    Restart-Service -Name $svc.Name -Force
    Start-Sleep -Seconds 3
    Write-Host "Authentication re-enabled." -ForegroundColor Green
}

# --- Prove the new password works ---------------------------------------
$env:PGPASSWORD = $s1
$env:PGHOST = "localhost"; $env:PGPORT = "5432"; $env:PGUSER = "postgres"

# Scoped to this call only: under "Stop", redirecting a native program's
# stderr makes any message it prints a terminating error, which would abort
# the check even when the login succeeded. The surrounding "Stop" is kept
# because it is what guarantees a failed pg_hba.conf copy aborts the run.
$prev = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$check = & $psql -d postgres -At -c "SELECT 'ok';" 2>&1
$ok = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = $prev

Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
Remove-Item Env:PGHOST     -ErrorAction SilentlyContinue
Remove-Item Env:PGPORT     -ErrorAction SilentlyContinue
Remove-Item Env:PGUSER     -ErrorAction SilentlyContinue

Write-Host ""
if ($ok) {
    Write-Host "Verified: the new password authenticates against the local server." -ForegroundColor Green
    Write-Host ""
    Write-Host "Now run the restore test (a normal, non-admin window is fine):"
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\scripts\verify-backup.ps1"
    Write-Host ""
    Write-Host "The backup copy of pg_hba.conf can be deleted once you are satisfied:"
    Write-Host "    $backup"
} else {
    Write-Host "The new password did NOT authenticate. Output was:" -ForegroundColor Red
    Write-Host "   $check"
    Write-Host "pg_hba.conf has been restored regardless - the server is not left open."
}

<#
.SYNOPSIS
    Takes a pg_dump backup of the Hops Supabase database.

.DESCRIPTION
    Wraps the pg_dump invocation so the connection URI never has to be
    typed into a command line. The URI carries the database password, and
    PowerShell writes every typed command to ConsoleHost_history.txt in
    plaintext, permanently. Values entered at a Read-Host prompt are not
    recorded there.

    The dump is written to backups/, which is gitignored - it contains
    every row in the cloud database (profiles, moderation records, the
    admin action log) and must never be committed.

.NOTES
    Run from the repository root:

        powershell -ExecutionPolicy Bypass -File .\scripts\backup-db.ps1

    The -ExecutionPolicy flag is needed because the machine default is
    Restricted; it applies to this one invocation only and changes nothing
    system-wide.
#>

param(
    [string]$OutputDir = "backups",

    # Hides the URI as it is entered. Use when the screen is being shared
    # or projected - the default prompt echoes what is pasted, and the URI
    # contains the database password. Off by default because seeing the
    # URI is genuinely useful when diagnosing a bad paste.
    [switch]$Masked
)

$ErrorActionPreference = "Stop"

# --- Locate pg_dump ------------------------------------------------------
# The EDB installer does not add its bin directory to PATH, so resolve the
# binary directly. Highest installed major version wins.
$pgDump = Get-Command pg_dump.exe -ErrorAction SilentlyContinue |
          Select-Object -First 1 -ExpandProperty Source

if (-not $pgDump) {
    $candidates = Get-ChildItem "C:\Program Files\PostgreSQL\*\bin\pg_dump.exe" -ErrorAction SilentlyContinue |
                  Sort-Object { [int]($_.Directory.Parent.Name) } -Descending
    if ($candidates) { $pgDump = $candidates[0].FullName }
}

if (-not $pgDump) {
    Write-Host "pg_dump not found." -ForegroundColor Red
    Write-Host "Install it with:  winget install PostgreSQL.PostgreSQL.17"
    exit 1
}

Write-Host "Using: $pgDump" -ForegroundColor DarkGray
& $pgDump --version

# --- Output path ---------------------------------------------------------
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}
$stamp  = Get-Date -Format "yyyyMMdd-HHmmss"
$target = Join-Path $OutputDir "hops_backup_$stamp.sql"

# --- Connection URI ------------------------------------------------------
Write-Host ""
Write-Host "Supabase: Project Settings > Database > Connection string > URI"
Write-Host "Choose Direct connection. If that fails to resolve, use the"
Write-Host "Session pooler. Never the Transaction pooler - pg_dump needs one"
Write-Host "continuous session to hold a consistent snapshot."
Write-Host ""
Write-Host "Replace [YOUR-PASSWORD] with the database password before pasting."
Write-Host ""

Write-Host "Paste ONLY the URI itself - one line beginning postgresql://"
Write-Host "and ending /postgres. Not a pg_dump command, not any flags."
Write-Host ""

if ($Masked) {
    $sec = Read-Host "Paste connection URI (input hidden)" -AsSecureString
    $raw = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
             [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
} else {
    $raw = Read-Host "Paste connection URI"
}

if ([string]::IsNullOrWhiteSpace($raw)) {
    Write-Host "Nothing entered. Stopping." -ForegroundColor Yellow
    exit 1
}

# People paste more than the URI - a whole command line, surrounding quotes,
# a trailing newline. A URI cannot contain whitespace or a quote, so pull out
# the URI and discard whatever else came along rather than handing pg_dump an
# argument list it will misread.
$m = [regex]::Match($raw, "postgres(?:ql)?://[^\s`"']+")

if (-not $m.Success) {
    Write-Host "That does not look like a connection URI." -ForegroundColor Red
    Write-Host "Expected one line in this shape:"
    Write-Host "  postgresql://postgres:PASSWORD@db.xxxxxxxx.supabase.co:5432/postgres"
    Write-Host ""
    Write-Host "In Supabase: Project Settings > Database > Connection string > URI."
    exit 1
}

$uri = $m.Value

if ($uri.Length -ne $raw.Trim().Length) {
    Write-Host "Note: extra text was pasted alongside the URI and has been ignored." -ForegroundColor Yellow
}

if ($uri -match "\[YOUR-PASSWORD\]") {
    Write-Host "The URI still contains the literal [YOUR-PASSWORD] placeholder." -ForegroundColor Red
    Write-Host "Replace it with the real database password, then run again."
    exit 1
}

# Echo it back with the password hidden, so a wrong host or a missing
# password is obvious before a connection is attempted.
$shown = [regex]::Replace($uri, "(postgres(?:ql)?://[^:@/]+:)([^@]*)(@)", '$1********$3')
Write-Host "Connecting as: $shown" -ForegroundColor DarkGray

# --- Dump ----------------------------------------------------------------
# --schema=public   skips Supabase-managed schemas (auth, storage, realtime)
#                   that a non-superuser cannot read and cannot restore into
#                   a new project anyway.
# --no-owner        strips ALTER ... OWNER TO for roles that only exist in
# --no-privileges   this project, so the dump can restore elsewhere.
Write-Host ""
Write-Host "Dumping to $target ..." -ForegroundColor Cyan

& $pgDump $uri --schema=public --no-owner --no-privileges -f $target
$code = $LASTEXITCODE

if ($code -ne 0) {
    Write-Host "pg_dump exited with code $code. Backup FAILED." -ForegroundColor Red
    if (Test-Path $target) { Remove-Item $target }
    exit $code
}

# --- Verify --------------------------------------------------------------
# An incomplete dump is worse than no dump, because it looks like a backup.
# pg_dump writes this marker only after the last object is written.
# Widen the window past the trailing \unrestrict line that pg_dump 17.6+
# emits after the marker, and test with -match rather than -notmatch:
# against an array, -notmatch returns the elements that do NOT match, which
# is a non-empty (truthy) array whenever any single line differs - so the
# check could never pass.
$tail = Get-Content $target -Tail 10
if (-not ($tail -match "PostgreSQL database dump complete")) {
    Write-Host "Dump did not end with its completion marker - it is TRUNCATED." -ForegroundColor Red
    Write-Host "Do not rely on this file."
    exit 1
}

$size  = (Get-Item $target).Length
$lines = (Get-Content $target | Measure-Object -Line).Lines

Write-Host ""
Write-Host "Backup complete." -ForegroundColor Green
Write-Host "  File:  $target"
Write-Host "  Size:  $([math]::Round($size / 1KB, 1)) KB"
Write-Host "  Lines: $lines"
Write-Host ""
Write-Host "Tables captured:" -ForegroundColor DarkGray
Select-String -Path $target -Pattern "^CREATE TABLE " |
    ForEach-Object { $_.Line -replace "^CREATE TABLE (public\.)?", "  " -replace " \($", "" }

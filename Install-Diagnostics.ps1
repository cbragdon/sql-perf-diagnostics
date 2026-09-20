<#
.SYNOPSIS
    Deploys the four diagnostic stored procedures into a DBA utility database.

.DESCRIPTION
    The four procedures are the "run it against any database on the instance" half of this toolset.
    The matching stand-alone scripts need no installation at all -- open them in SSMS, point the
    window at the database you want to analyse, and run. This installer exists only for the
    procedure half.

    WHAT IT DOES, in order:
      1. Confirms sqlcmd is on PATH.
      2. Connects and reports the engine version and edition.
      3. Confirms the utility database exists (it will NOT create one -- see below).
      4. Runs each of the four procedure files against that database.
      5. Re-reads sys.procedures and confirms all four now exist.

    WHAT IT DELIBERATELY DOES NOT DO:
      - It never creates a database. If the utility database is missing the script stops and prints
        the CREATE DATABASE statement for you to review and run yourself.
      - It never stores or accepts a password. Authentication is integrated (sqlcmd -E) under
        whoever runs the script; there is no -SqlCredential, -User or -Password parameter, and
        adding one is against this project's rules.
      - It never enforces an engine-version floor of its own. Each procedure self-gates at run time
        and aborts with its own message naming what it needs, which is more accurate than a single
        number here could be.

    PERMISSIONS to run this installer: CREATE PROCEDURE in the utility database, and ALTER on its
    dbo schema (db_ddladmin or db_owner covers both). The permissions needed to USE the procedures
    afterwards are different and are documented per tool in the USAGE-*.md files -- typically
    VIEW SERVER STATE (VIEW SERVER PERFORMANCE STATE on 2022+), VIEW DATABASE STATE and SHOWPLAN.

.PARAMETER SqlInstance
    Target instance. Default 'localhost'. Named instances and host,port both work:
    'LAPTOP\SQL2022', 'tcp:sqlvm01,1433'.

.PARAMETER UtilityDatabase
    Database the procedures are created in. Default 'DBAdmin'. Any database works -- the procedure
    files carry no USE statement and no hard-coded database name, so they are created wherever the
    connection points.

.PARAMETER WhatIf
    List what would be deployed and exit without changing anything.

.EXAMPLE
    .\Install-Diagnostics.ps1
    Deploys to DBAdmin on localhost.

.EXAMPLE
    .\Install-Diagnostics.ps1 -SqlInstance 'LAPTOP\SQL2022' -UtilityDatabase 'DBATools'
    Deploys to a named instance and a differently-named utility database.

.EXAMPLE
    .\Install-Diagnostics.ps1 -WhatIf
    Shows the four files and the target, changes nothing.
#>
[CmdletBinding()]
param(
    [string] $SqlInstance     = 'localhost',
    [string] $UtilityDatabase = 'DBAdmin',
    [switch] $WhatIf
)

$ErrorActionPreference = 'Stop'

#   PowerShell returns exit code 0 for an unhandled terminating error under -File unless the script
#   exits explicitly, so a crash would otherwise look like a clean install to any caller checking
#   the exit code.
trap {
    Write-Host ("  ERROR  {0} (line {1})" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) -ForegroundColor Red
    exit 1
}

$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path -Parent }

#   Procedure file -> the object it must create. The second half is what step 5 verifies; without it
#   a file that ran but created nothing (or created something misnamed) would report success.
$Procedures = [ordered]@{
    'usp_ParameterSniffingDiagnostic.sql'      = 'usp_ParameterSniffingDiagnostic'
    'usp_FindTimeoutStatementsNQueryStore.sql' = 'usp_FindTimeoutStatementsNQueryStore'
    'usp_IndexAnalysis.sql'                    = 'usp_IndexAnalysis'
    'usp_TippingPointAnalysis.sql'             = 'usp_TippingPointAnalysis'
}

function Invoke-Scalar {
    param([string] $Database, [string] $Query)
    $out = & sqlcmd -S $SqlInstance -d $Database -E -C -I -h -1 -W -b -Q $Query
    if ($LASTEXITCODE -ne 0) {
        throw ("sqlcmd failed against {0} (exit {1}): {2}" -f $SqlInstance, $LASTEXITCODE, ($out -join ' '))
    }
    #   -h -1 suppresses headers; the value is the first non-empty line.
    return (@($out) | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1).Trim()
}

Write-Host ''
Write-Host '=== SQL Server diagnostic toolset -- procedure install =========================' -ForegroundColor Cyan
Write-Host ("  instance          : {0}" -f $SqlInstance)
Write-Host ("  utility database  : {0}" -f $UtilityDatabase)
Write-Host ("  source folder     : {0}" -f $root)
Write-Host ''

# --- 1. sqlcmd present ----------------------------------------------------------------------
$sqlcmdPath = (Get-Command sqlcmd -ErrorAction SilentlyContinue)
if (-not $sqlcmdPath) {
    Write-Host '  sqlcmd is not on PATH. Install the SQL Server command line utilities, or run the' -ForegroundColor Red
    Write-Host '  four usp_*.sql files by hand in SSMS against your utility database instead.' -ForegroundColor Red
    exit 1
}

# --- 2. every source file present, before anything is deployed ------------------------------
$missing = @()
foreach ($f in $Procedures.Keys) {
    if (-not (Test-Path (Join-Path $root $f))) { $missing += $f }
}
if ($missing.Count) {
    Write-Host ("  Missing source file(s): {0}" -f ($missing -join ', ')) -ForegroundColor Red
    Write-Host '  Run this from the folder the files were downloaded into.' -ForegroundColor Red
    exit 1
}

if ($WhatIf) {
    Write-Host '  -WhatIf: would deploy these four files, and change nothing else:' -ForegroundColor Yellow
    foreach ($f in $Procedures.Keys) { Write-Host ("     {0}  ->  dbo.{1}" -f $f, $Procedures[$f]) }
    Write-Host ''
    exit 0
}

# --- 3. connect, and say what we are talking to ---------------------------------------------
$version = Invoke-Scalar -Database 'master' -Query @"
SET NOCOUNT ON;
SELECT CONVERT(varchar(20), SERVERPROPERTY('ProductVersion')) + ' | '
     + CONVERT(varchar(60), SERVERPROPERTY('Edition'));
"@
Write-Host ("  connected         : {0}" -f $version) -ForegroundColor Green

# --- 4. utility database exists -------------------------------------------------------------
$dbEscaped = $UtilityDatabase.Replace("'", "''")
$dbExists = Invoke-Scalar -Database 'master' -Query @"
SET NOCOUNT ON;
SELECT COUNT(*) FROM sys.databases WHERE name = N'$dbEscaped';
"@
if ([int]$dbExists -eq 0) {
    Write-Host ''
    Write-Host ("  Database [{0}] does not exist on {1}." -f $UtilityDatabase, $SqlInstance) -ForegroundColor Red
    Write-Host '  This installer does not create databases. Review and run this yourself, then re-run:' -ForegroundColor Red
    Write-Host ''
    Write-Host ("      CREATE DATABASE [{0}];" -f $UtilityDatabase) -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Or point the installer at a utility database you already have:' -ForegroundColor Red
    Write-Host ("      .\Install-Diagnostics.ps1 -SqlInstance '{0}' -UtilityDatabase 'YourDb'" -f $SqlInstance) -ForegroundColor Yellow
    exit 1
}

# --- 5. deploy ------------------------------------------------------------------------------
Write-Host ''
foreach ($f in $Procedures.Keys) {
    $path = Join-Path $root $f
    #   -b so a SQL error sets a non-zero exit code; -I for QUOTED_IDENTIFIER, which the XML
    #   methods in these procedures require.
    $out = & sqlcmd -S $SqlInstance -d $UtilityDatabase -E -C -I -b -i $path
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("  FAILED   {0}" -f $f) -ForegroundColor Red
        $out | Where-Object { $_ -match 'Msg |Level |Line ' } | Select-Object -First 8 |
            ForEach-Object { Write-Host ("           {0}" -f $_) -ForegroundColor Red }
        exit 1
    }
    Write-Host ("  deployed  {0}" -f $f) -ForegroundColor Green
}

# --- 6. verify the objects are actually there -----------------------------------------------
Write-Host ''
$absent = @()
foreach ($f in $Procedures.Keys) {
    $name = $Procedures[$f]
    $n = Invoke-Scalar -Database $UtilityDatabase -Query @"
SET NOCOUNT ON;
SELECT COUNT(*) FROM sys.procedures WHERE name = N'$name' AND SCHEMA_NAME(schema_id) = N'dbo';
"@
    if ([int]$n -ne 1) { $absent += $name }
}
if ($absent.Count) {
    Write-Host ("  Deployed without error, but these are not in sys.procedures: {0}" -f ($absent -join ', ')) -ForegroundColor Red
    exit 1
}

Write-Host ("  verified  all 4 procedures exist in [{0}].dbo" -f $UtilityDatabase) -ForegroundColor Green
Write-Host ''
Write-Host '=== INSTALLED ==================================================================' -ForegroundColor Cyan
Write-Host '  Try one, against a database that has Query Store on:'
Write-Host ''
Write-Host ("      EXEC [{0}].dbo.usp_ParameterSniffingDiagnostic @DatabaseName = N'YourDatabase';" -f $UtilityDatabase) -ForegroundColor Yellow
Write-Host ''
Write-Host '  Always pass @DatabaseName -- it defaults to the CURRENT database, so a bare call from'
Write-Host ("  a [{0}] window analyses [{0}] itself." -f $UtilityDatabase)
Write-Host '  Per-tool parameters, permissions and how to read the output: the USAGE-*.md files.'
Write-Host ''
exit 0

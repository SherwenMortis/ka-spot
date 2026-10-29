# Local SQL verification runner. Writes build\verify-log.txt (gitignored).
#
# What it verifies, in one process:
#   0  harness provisioning (auth.uid(), realtime.messages)
#   C  clean install: schema.sql -> every migration -> contract -> 4 suites
#   I  idempotency: every migration and schema.sql again, contract, duplicates
#   U  upgrade path: the schema at HEAD~1 -> migrations -> before/after probes
#
# Requirements: a running Docker engine and, once per engine start,
#   docker run -d --name kaspot-verify-pg --rm -e POSTGRES_PASSWORD=postgres \
#     -p 127.0.0.1:54322:5432 public.ecr.aws/supabase/postgres:17.11.0.004
# The Supabase image matters: it brings the anon/authenticated/service_role
# roles, the GoTrue auth schema and the platform default privileges
# (anon=X on new public functions) that migration 20261024 exists to correct.
#
# Target guard: this script only ever talks to the container named below, and it
# aborts if that container publishes anything other than a loopback address. It
# never uses `--linked`, never reads supabase/.temp, and never contacts a hosted
# project.
#
# ASCII only on purpose: PowerShell 5.1 decodes a BOM-less .ps1 as ANSI.

$ErrorActionPreference = 'Continue'
$c = 'kaspot-verify-pg'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$out  = Join-Path $root 'build'
if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out | Out-Null }
$log = Join-Path $out 'verify-log.txt'
Set-Content -Path $log -Value ("KaSpot local SQL verification - " + (Get-Date -Format o))
$script:failures = @()

function Log([string]$m) { Add-Content -Path $log -Value $m; Write-Host $m }

# --- target guard ------------------------------------------------------------
$ports = docker port $c 2>&1
if ($LASTEXITCODE -ne 0) { throw "container $c is not running" }
foreach ($p in $ports) {
  $s = "$p"
  # docker port prints '5432/tcp -> 127.0.0.1:54322'
  if ($s -match '0\.0\.0\.0:|:::|\[::\]:') { throw "non-loopback binding on $c : $s" }
  if ($s -notmatch '127\.0\.0\.1:\d+') { throw "unexpected binding on $c : $s" }
}
Log ("TARGET container=$c ports=" + ($ports -join ','))
Log ("DATABASE " + (docker exec $c psql -U postgres -d postgres -tAc "select current_database();" 2>&1))

docker exec $c mkdir -p /work | Out-Null

function Sql([string]$path, [string]$label, [string]$user = 'postgres') {
  $name = Split-Path $path -Leaf
  docker cp $path "${c}:/work/$name" 2>&1 | Out-Null
  $out = docker exec $c psql -U $user -d postgres -v ON_ERROR_STOP=1 -q -f "/work/$name" 2>&1
  $code = $LASTEXITCODE
  Log ("== {0}  [{1}]  exit={2}" -f $label, $name, $code)
  foreach ($line in $out) { if ("$line".Trim().Length -gt 0) { Log ("   " + $line) } }
  if ($code -ne 0) { $script:failures += "$label ($name)" }
  return $code
}

$migrations = Get-ChildItem (Join-Path $root 'supabase\migrations\*.sql') | Sort-Object Name
$tests      = Join-Path $root 'supabase\tests'

# --- 0. harness services -----------------------------------------------------
# Run as supabase_admin: auth/realtime are owned by supabase roles. Everything
# after this runs as postgres, exactly like the SQL editor does in production.
Sql (Join-Path $PSScriptRoot 'harness-bootstrap.sql') '0 bootstrap' 'supabase_admin'

# --- 1. schema.sql ALONE (the file claims to be complete on its own) --------
# If this fails, schema.sql is missing something a migration only adds, and the
# header comment in schema.sql is a lie.
Sql (Join-Path $PSScriptRoot 'reset-public.sql')      'S0 reset public'
Sql (Join-Path $root 'supabase\schema.sql')           'S1 schema.sql alone'
Sql (Join-Path $tests 'install_contract.sql')         'S2 install_contract'

# --- 2. CLEAN INSTALL --------------------------------------------------------
Sql (Join-Path $PSScriptRoot 'reset-public.sql')      'C0 reset public'
Sql (Join-Path $root 'supabase\schema.sql')           'C1 schema.sql'
foreach ($m in $migrations) { Sql $m.FullName ('C2 ' + $m.Name) }
Sql (Join-Path $PSScriptRoot 'harness-fixtures.sql')  'C3 fixtures'
Sql (Join-Path $tests 'install_contract.sql')         'C4 install_contract'
Sql (Join-Path $tests 'rpc_caller_scope.sql')         'C5 rpc_caller_scope'
Sql (Join-Path $tests 'chat_channel_authorization.sql') 'C6 chat_channel_authorization'
Sql (Join-Path $tests 'location_retention.sql')       'C7 location_retention'
Sql (Join-Path $tests 'rollback_drill.sql')           'C8 rollback_drill'

# --- 2. IDEMPOTENCY: everything again, same database -------------------------
foreach ($m in $migrations) { Sql $m.FullName ('I1 ' + $m.Name) }
Sql (Join-Path $root 'supabase\schema.sql')           'I2 schema.sql rerun'
Sql (Join-Path $tests 'install_contract.sql')         'I3 install_contract'
Sql (Join-Path $PSScriptRoot 'counts.sql')            'I4 duplicate counts'

# --- 3. UPGRADE PATH: previous schema, then the migrations -------------------
$head1 = Join-Path $out 'schema-head1.sql'
$lines = & git -C $root show 'HEAD~1:supabase/schema.sql'
[IO.File]::WriteAllLines($head1, $lines, (New-Object System.Text.UTF8Encoding($false)))

Sql (Join-Path $PSScriptRoot 'reset-public.sql')      'U0 reset public'
Sql $head1                                            'U1 schema at HEAD~1'
Sql (Join-Path $PSScriptRoot 'harness-fixtures.sql')  'U2 fixtures'
Sql (Join-Path $PSScriptRoot 'legacy-location.sql')   'U3 legacy location'
Sql (Join-Path $PSScriptRoot 'verify-upgrade-before.sql') 'U4 before probe'
foreach ($m in $migrations) { Sql $m.FullName ('U5 ' + $m.Name) }
Sql (Join-Path $PSScriptRoot 'verify-upgrade-after.sql')  'U6 after probe'
Sql (Join-Path $tests 'install_contract.sql')         'U7 install_contract'
Sql (Join-Path $tests 'rpc_caller_scope.sql')         'U8 rpc_caller_scope'
Sql (Join-Path $PSScriptRoot 'counts.sql')            'U9 duplicate counts'

# --- summary -----------------------------------------------------------------
if ($script:failures.Count -eq 0) {
  Log 'SUMMARY: every step exited 0'
} else {
  Log ('SUMMARY: FAILED steps -> ' + ($script:failures -join '; '))
}

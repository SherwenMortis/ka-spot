# Driver for the live private-channel verification.
#   powershell -ExecutionPolicy Bypass -File .\tool\live_check_run.ps1
#
# Step A: resolve and guard the target project (live_check_env.ps1).
# Step B: create the throwaway accounts through the Auth Admin API.
# Step C: record the accepted connection between the first two of them.
# Step D: run the real WebSocket check.
#
# The target is never inferred. live_check_env.ps1 requires
# KASPOT_PROJECT_REF, refuses a value that disagrees with SUPABASE_URL, and
# refuses the production project unless KASPOT_ALLOW_PRODUCTION=1.
#
# Required for step C: SUPABASE_DB_URL, the STAGING connection string
# (Dashboard -> Project Settings -> Database -> Connection string). It must name
# the same project ref as SUPABASE_URL; the guard below enforces that.
. .\tool\live_check_env.ps1
if (-not $env:LIVECHECK_SERVICE_KEY) { exit 1 }

if (-not $env:SUPABASE_DB_URL) {
  [Console]::Error.WriteLine('SUPABASE_DB_URL is not set. Step C records the accepted connection through psql, which needs the staging database connection string.')
  exit 1
}

if ($env:SUPABASE_DB_URL -notmatch [regex]::Escape($env:KASPOT_TARGET_REF)) {
  [Console]::Error.WriteLine("SUPABASE_DB_URL does not name the target project ($($env:KASPOT_TARGET_REF)). Refusing to run SQL against a different database.")
  exit 1
}

dart run tool/live_check_accounts.dart
if ($LASTEXITCODE -ne 0) { exit 1 }

# `supabase db query` does not exist in CLI 2.120.0 (db offers only
# diff/dump/push/pull/reset/start), so the SQL file is applied with psql.
& psql $env:SUPABASE_DB_URL -v ON_ERROR_STOP=1 -f supabase/tmp_live_connect.sql
if ($LASTEXITCODE -ne 0) { exit 1 }

dart run tool/live_realtime_private_check.dart

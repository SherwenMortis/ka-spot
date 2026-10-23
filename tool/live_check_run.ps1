# Driver for the live private-channel verification.
#   powershell -ExecutionPolicy Bypass -File .\tool\live_check_run.ps1
# Step A: create the throwaway accounts through the Auth Admin API.
# Step B: record the accepted connection between the first two of them.
# Step C: run the real WebSocket check.
. .\tool\live_check_env.ps1
if ($LASTEXITCODE -ne 0 -or -not $env:LIVECHECK_SERVICE_KEY) { exit 1 }

dart run tool/live_check_accounts.dart
if ($LASTEXITCODE -ne 0) { exit 1 }

& 'C:\Users\PC\AppData\Roaming\npm\supabase.cmd' db query -f supabase/tmp_live_connect.sql --linked 2>&1 | Out-String
dart run tool/live_realtime_private_check.dart

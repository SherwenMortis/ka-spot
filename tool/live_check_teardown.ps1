# Removes the throwaway accounts the live private-channel check created. They came
# from the Auth Admin API, so they are removed the same supported way; every app
# row the check wrote (connection, probe message) references auth.users with
# `on delete cascade`, so those go with them.
#
#   powershell -ExecutionPolicy Bypass -File .\tool\live_check_teardown.ps1
. .\tool\live_check_env.ps1
if (-not $env:LIVECHECK_SERVICE_KEY) { exit 1 }

$envVars = [ordered]@{}
foreach ($line in (Get-Content .env)) {
  $t = $line.Trim()
  if ($t -eq '' -or $t.StartsWith('#')) { continue }
  $i = $t.IndexOf('=')
  if ($i -gt 0) { $envVars[$t.Substring(0, $i)] = $t.Substring($i + 1).Trim() }
}
$url = $envVars['SUPABASE_URL']
$service = $env:LIVECHECK_SERVICE_KEY
$headers = @{ apikey = $service; Authorization = "Bearer $service" }

$listed = Invoke-RestMethod -Uri "$url/auth/v1/admin/users?page=1&per_page=500" -Headers $headers
$users = if ($listed -is [array]) { $listed } else { $listed.users }
$remaining = 0
foreach ($u in $users) {
  if ($u.email -like 'kaspot.livecheck.*') {
    Invoke-RestMethod -Method Delete -Uri "$url/auth/v1/admin/users/$($u.id)" -Headers $headers | Out-Null
    Write-Output "dropped $($u.email)"
  }
}

$after = Invoke-RestMethod -Uri "$url/auth/v1/admin/users?page=1&per_page=500" -Headers $headers
$afterUsers = if ($after -is [array]) { $after } else { $after.users }
$remaining = @($afterUsers | Where-Object { $_.email -like 'kaspot.livecheck.*' }).Count
Write-Output "throwaway accounts remaining: $remaining"

# Loads a service-role key for the linked project into LIVECHECK_SERVICE_KEY without
# printing it, so the throwaway live-check accounts can be created and removed
# through the supported Auth Admin API instead of by editing auth.users rows.
$cli = 'C:\Users\PC\AppData\Roaming\npm\supabase.cmd'
$ref = 'etuosispxwfmvcupjhkv'

function Get-Keys([string[]]$extra) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $out = & $cli 'projects' 'api-keys' '--project-ref' $ref @extra 2>&1 | Out-String
  $ErrorActionPreference = $prev
  return ($out -replace 'A new version of Supabase CLI[\s\S]*', '')
}

$secret = $null
foreach ($variant in @(@('--json'), @())) {
  $text = Get-Keys $variant
  foreach ($line in ($text -split "`n")) {
    # json: {"name":"service_role","value":"..."}   table: "  service_role | <key> "
    if ($line -match '"name"\s*:\s*"service_role".*?"(value|secret)"\s*:\s*"([^"]+)"') {
      $secret = $Matches[2]
    } elseif ($line -match 'service_role\s*\|\s*(\S{40,})') {
      $secret = $Matches[1].Trim(' |')
    }
    if ($secret) { break }
  }
  if ($secret) { break }
}

if (-not $secret) {
  Write-Output 'SERVICE_KEY_FOUND=0'
  exit 1
}

$env:LIVECHECK_SERVICE_KEY = $secret
Write-Output "SERVICE_KEY_FOUND=1 length=$($secret.Length)"

# Resolves WHICH project the live checks will run against, and loads that
# project's service-role key into LIVECHECK_SERVICE_KEY without printing it.
#
# Dot-sourced by live_check_run.ps1 and live_check_teardown.ps1:
#   . .\tool\live_check_env.ps1
#
# Why this guard exists
# ---------------------
# The project ref used to be hard-coded to the production project while the Dart
# scripts read SUPABASE_URL from .env, so the CLI and the harness could silently
# point at different projects — and both pointed at production by default. The
# ref is now an explicit input, it must agree with .env, and the production
# project is refused unless it is named on purpose.
#
# Inputs
#   KASPOT_PROJECT_REF      required. Must equal the ref in SUPABASE_URL.
#   SUPABASE_URL            optional. Falls back to .env in the current directory.
#   KASPOT_ALLOW_PRODUCTION optional. Set to 1 to permit the production project.
#   KASPOT_SUPABASE_CLI     optional. Overrides the CLI path below.
#
# Output (machine-readable, never the key itself)
#   TARGET_REF=<ref>
#   SERVICE_KEY_FOUND=1 length=<n>

# Errors are written to stderr and end the script. The caller's
# $ErrorActionPreference is deliberately left alone: this file is dot-sourced.

$cli = if ($env:KASPOT_SUPABASE_CLI) { $env:KASPOT_SUPABASE_CLI }
       else { Join-Path $env:APPDATA 'npm\supabase.cmd' }

# The one project a staging check must never touch.
$productionRef = 'etuosispxwfmvcupjhkv'

function Read-DotEnvValue([string]$name) {
  $path = Join-Path (Get-Location) '.env'
  if (-not (Test-Path $path)) { return $null }
  foreach ($line in Get-Content $path) {
    $t = $line.Trim()
    if ($t.Length -eq 0 -or $t.StartsWith('#')) { continue }
    $i = $t.IndexOf('=')
    if ($i -gt 0 -and $t.Substring(0, $i).Trim() -eq $name) {
      return $t.Substring($i + 1).Trim()
    }
  }
  return $null
}

$url = if ($env:SUPABASE_URL) { $env:SUPABASE_URL } else { Read-DotEnvValue 'SUPABASE_URL' }

if (-not $url) {
  [Console]::Error.WriteLine('No SUPABASE_URL: set $env:SUPABASE_URL or create .env. Refusing to guess a project.')
  exit 1
}

$hostName = ([Uri]$url).Host
if ($hostName -notmatch '^([a-z0-9]+)\.supabase\.(co|in)$') {
  [Console]::Error.WriteLine("SUPABASE_URL host '$hostName' is not a hosted Supabase project. The live checks need the staging project, not a local stack.")
  exit 1
}
$ref = $Matches[1]

if (-not $env:KASPOT_PROJECT_REF) {
  [Console]::Error.WriteLine("KASPOT_PROJECT_REF is not set. Set it to '$ref' (the ref in SUPABASE_URL) so the CLI and this harness cannot disagree. Production is '$productionRef'.")
  exit 1
}

if ($env:KASPOT_PROJECT_REF -ne $ref) {
  [Console]::Error.WriteLine("Project mismatch: KASPOT_PROJECT_REF=$($env:KASPOT_PROJECT_REF) but SUPABASE_URL points at '$ref'. Refusing to run: the SQL steps and the app would act on different projects.")
  exit 1
}

if ($ref -eq $productionRef -and $env:KASPOT_ALLOW_PRODUCTION -ne '1') {
  [Console]::Error.WriteLine("Refusing to run against the production project ($productionRef). Use the staging project. To run a deliberate production smoke test, set `$env:KASPOT_ALLOW_PRODUCTION = '1' and record it in the run notes.")
  exit 1
}

# Exported so the caller can cross-check any other connection string it uses.
$env:KASPOT_TARGET_REF = $ref

Write-Output "TARGET_REF=$ref"
if ($ref -eq $productionRef) {
  Write-Output 'WARNING=TARGET_IS_PRODUCTION'
}

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

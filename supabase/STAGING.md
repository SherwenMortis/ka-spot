# Isolated staging verification

Nothing in this repository deploys, migrates or deletes by itself. This file is
the checklist for doing that once, on a project that is **not** the linked
production project (`etuosispxwfmvcupjhkv`, name "Ka-Spot").

## 1. Status when this revision was written

Read this before trusting any other file. Every line below is a statement about
what has actually been executed, not about what is prepared.

| Item | State |
|---|---|
| Hosted staging project | **Does not exist.** This is the blocking prerequisite (§2.1). |
| Migration applied anywhere | **No.** No migration in `supabase/migrations/` has been applied to any project. |
| Edge Function deployed anywhere | **No.** Neither `notify-new-message` nor `delete-account` is deployed. |
| SQL suites executed | **Yes, locally**: 45/45 steps green against a local Supabase Postgres image (17.11.0.004) — `schema.sql` alone, clean install, upgrade from the previous schema, idempotency, and all four suites. See `supabase/tests/harness/`. **Not** executed against a hosted project. |
| pg_cron job scheduled | **No.** The procedure is verified locally against pg_cron 1.6.4 (scheduled, executed, purged, disabled); no job exists in any hosted environment (`supabase/ops/`). |
| FCM delivery to a real device | **Not verified.** No staging Firebase service account exists yet. |
| Physical Android device run | **Not executed.** Widget tests only. |
| Account deletion in a release build | Disabled by default (`ReleaseFlags.accountDeletionEnabled`). Must stay disabled until §4.8–§4.9 pass on a real device. |

A green local run is not evidence about the hosted environment: the local stack
supplies different default privileges, a different `realtime` schema version and
no HTTP egress. Nothing in §4 may be reported as passed on the strength of a
local run.

## 2. Prerequisites

### 2.1 The hosted staging project (owner action — blocking)

Creating a Supabase project requires Dashboard access (or an organisation-scoped
access token) that this repository does not hold. Until someone with those
credentials does the following, every step in §4 is blocked:

1. Create a **new** project in the same organisation, named unambiguously
   (e.g. `KaSpot Staging`), on a paid plan if Realtime + Edge Functions are
   needed. Write its project ref down, e.g. `abcdefghijklmnop`.
2. Confirm it is **not** `etuosispxwfmvcupjhkv`:

   ```bash
   supabase projects list          # both refs must appear, and differ
   ```

3. Decide the boundary this repo assumes:

   | Resource | Staging | Production |
   |---|---|---|
   | Supabase project | new project, separate ref | `etuosispxwfmvcupjhkv` |
   | Database password | new, stored in the password manager | unchanged |
   | `SUPABASE_ANON_KEY` | staging publishable key | never copied into a staging build |
   | Service-role key | staging only, never leaves the operator shell | never used for staging checks |
   | `KASPOT_WEBHOOK_SECRET` | newly generated for staging | separate value |
   | Firebase service account | staging Firebase project | production project |
   | Accounts | disposable, listed in §2.4 | real people |

**Never silently fall back to the linked project.** This machine's CLI is linked
to production (`supabase/.temp/linked-project.json` → `etuosispxwfmvcupjhkv`).
Therefore:

* do **not** run `supabase link` for staging, and do not rely on the implicit link;
* pass `--project-ref <staging>` on every `supabase` command in §4;
* run every `psql` against `$KASPOT_STAGING_DATABASE_URL`, never a URL that was
  copied from the production dashboard;
* `tool/live_check_env.ps1` refuses to run unless `KASPOT_PROJECT_REF` is set and
  matches the host in `.env` (see §7.1). Read it before using the harness.

### 2.2 Tooling

| Item | Version used here | Note |
|---|---|---|
| Supabase CLI | 2.120.0 | `supabase db` has **no `query` subcommand** in this version. Use `psql`. |
| `psql` | 15+ | Not installed on the machine this was written on. Required for every SQL step. Install the PostgreSQL client or use the Dashboard SQL editor one file at a time. |
| Deno | 2.9.6+ (`npx deno@2`) | For `deno check` / `deno test` only. |
| Flutter | as pinned by `pubspec.yaml` | For the Android staging build (§7). |
| Docker Desktop | only for the local stack | Not required for hosted staging. |

### 2.3 Function secrets (staging project only)

```bash
supabase secrets set --project-ref <staging> \
  KASPOT_WEBHOOK_SECRET="$(openssl rand -hex 32)" \
  GOOGLE_WEB_CLIENT_ID="<staging web client id>" \
  FIREBASE_SERVICE_ACCOUNT_JSON="$(cat staging-service-account.json)"
```

* `KASPOT_WEBHOOK_SECRET` — 64 hex characters, at least 32. Shared **only**
  between the Edge Function and the Database Webhook. It is not an API key: it
  cannot be replayed against PostgREST, which is why it is used instead of the
  project secret key.
* `GOOGLE_WEB_CLIENT_ID` — the audience the Google ID token must carry.
* `FIREBASE_SERVICE_ACCOUNT_JSON` — staging Firebase service account.
* `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` are injected
  by the platform; never copy them into `.env`, the Flutter app or this repo.

### 2.4 Disposable accounts

Staging only, never real people, created through the Auth Admin API:

* A and B — an accepted connection, A shares location with B.
* C and D — a second accepted connection with at least one message between them.
  `supabase/tests/rpc_caller_scope.sql` needs two disjoint pairs.
* E — a user with no connections, used as the outsider.
* F — a Google-only account, for the Google deletion path (§4.8).

Google sign-in needs the staging project's OAuth client to list the staging
redirect/Android package; a client id borrowed from production will fail the
audience check in `delete-account` on purpose.

## 3. Database installation

Two paths, one end state. `supabase/schema.sql` is the complete definition of the
current schema, which is what makes a clean install possible at all; the
migrations are what upgrade an existing database, and they are idempotent
re-assertions of the same definitions. Neither is "the" source of truth on its
own: **the contract is.**

### 3.1 Clean install (new database, e.g. the new staging project)

```bash
export KASPOT_STAGING_DATABASE_URL='postgresql://postgres:<pw>@db.<staging>.supabase.co:5432/postgres'

psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/schema.sql

for f in supabase/migrations/*.sql; do
  echo "== $f"
  psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f" || exit 1
done

psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f supabase/tests/install_contract.sql
```

Order is filename order (`20261020…` → `20261024…`), which is also dependency
order: the retention migration needs `public.locations`, the private-channel
migration needs `public.is_accepted_connection`, and the caller-scope migration
guards its revokes with `to_regprocedure` so it also survives a database built
without the private-channel migration.

**Do not bootstrap the project with `supabase db push`.** Verified against an
empty database: the first migration fails with `relation "public.circle_messages"
does not exist`, because the migration set assumes `schema.sql` has already run
and `db push` only replays `supabase/migrations/`. It would also write partial
rows into `supabase_migrations.schema_migrations`, making later CLI runs believe
files were applied. Apply `schema.sql` with `psql` first, as above; reserve
`db push` for projects that are already on this schema.

A clean install must not be built from `schema.sql` alone: until this revision
the file did not define the two private-channel functions or their
`realtime.messages` policies, so a fresh database had **no Realtime channel
authorization**. `install_contract.sql` C5 now fails if that regresses.

### 3.2 Upgrade path (a database that already existed)

```bash
# Read-only capture first (§4.1). Then, in filename order:
for f in supabase/migrations/*.sql; do
  psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f" || exit 1
done

psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f supabase/tests/install_contract.sql
```

The upgrade case that matters is a database created **before** the retention
columns existed: `create table if not exists public.locations` does not add
columns to an existing table, so `schema.sql` alone cannot upgrade it — and the
`ALTER TABLE … ADD COLUMN … DEFAULT now() + interval` shortcut is deliberately
not used, because a volatile default would hand every legacy row a fresh 24 hour
window instead of letting already-old rows expire immediately. Only
`20261023_location_retention_expiration.sql` does the clamped backfill.

To prove the upgrade path rather than assume it, build the fixture from the
hosted project's own shape:

```bash
# read-only against the source project; no writes, no migration
pg_dump --schema-only --no-owner --no-privileges "$KASPOT_PROD_READONLY_URL" \
  > /tmp/kaspot-prod-schema.sql
psql "$KASPOT_SCRATCH_DATABASE_URL" -v ON_ERROR_STOP=1 -f /tmp/kaspot-prod-schema.sql
# then 3.2 against the scratch database, then install_contract.sql
```

Do this on a scratch database, never on staging or production. If the source is
production, treat the dump as sensitive: it contains the webhook trigger
definition and therefore the webhook header value.

### 3.3 What the contract test asserts

`supabase/tests/install_contract.sql` is read-only and checks, after either path:

* the 11 app tables exist with RLS enabled, and none has RLS-without-policy;
* migration-introduced columns exist with their final nullability
  (`locations.received_at`/`expires_at` NOT NULL, `device_tokens.supports_data_only`
  NOT NULL, the rest nullable);
* 17 functions exist **exactly once** — a duplicate overload is not caught by
  `create or replace` and silently changes which version a policy calls;
* 7 triggers exist exactly once, and no second trigger on `public.locations`
  runs the retention function;
* 29 policies exist exactly once, including both `realtime.messages` policies;
* `anon` and `PUBLIC` hold no EXECUTE on any client RPC and no table privilege;
  `authenticated` holds EXECUTE on exactly its six; `service_role` holds the two
  internal helpers and not the public wrappers;
* `kaspot_internal` is unreachable from a client role;
* **both public wrappers still contain an `auth.uid()` predicate** — this is the
  rollback detector from §8;
* `delete_expired_locations()` is executable by `postgres` and by no client role.

## 4. Verification sequence (run once a staging project exists)

Every step states the result that makes it a pass. Run them in order; a failed
step stops the sequence.

### 4.1 Capture the existing schema, migrations and effective permissions

```bash
pg_dump --schema-only --no-owner "$KASPOT_STAGING_DATABASE_URL" > staging-before.sql
psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f supabase/tests/install_contract.sql        # expected to FAIL on a bare project
psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 -c "
  select n.nspname, p.proname, p.proacl
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public','kaspot_internal') order by 1,2;" > acl-before.txt
```

**Pass:** both files exist and are kept with the staging run record; the contract
test's failures are recorded before the migrations are applied (that difference
is the evidence the migrations did something).

### 4.2 Apply the caller-scope migration and verify the resulting grants

```bash
psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f supabase/migrations/20261024_rpc_caller_scope.sql
psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f supabase/tests/install_contract.sql
```

**Pass:** the migration commits (its own in-transaction post-conditions are the
first gate) and the contract test passes. `anon` holds nothing; `authenticated`
holds `is_accepted_connection`/`is_valid_reply` and the four other client RPCs;
`service_role` holds only the `kaspot_internal` helpers.

### 4.3 Run the SQL suites

```bash
for f in supabase/tests/rpc_caller_scope.sql \
         supabase/tests/chat_channel_authorization.sql \
         supabase/tests/location_retention.sql \
         supabase/tests/rollback_drill.sql; do
  echo "== $f"
  psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f" || exit 1
done
```

**Pass:** `rpc_caller_scope: G1-G8 passed`, `chat_channel_authorization: S1-S6
passed`, `location retention checks passed (retention = 24:00:00)`,
`rollback_drill: R1-R5 passed`. Each file rolls itself back; a second run must
produce the same result (that also proves the fixtures are not persisted).

The suites need real data: at least two accepted connections, at least one
message, and a signed-in-capable user with no connections. See §2.4.

### 4.4 Private Realtime subscription and delivery

This is the only check that goes over a real WebSocket; the SQL suite in §4.3
drives the same policies but not the server.

```bash
# §7.1 for the guard; this must print the staging ref, not production
powershell -ExecutionPolicy Bypass -File .\tool\live_check_run.ps1
```

**Pass:** A and B each report `subscribed`; a broadcast sent by A is received by
B; the outsider's join is refused; the map channel (`kaspot-location-map-<uid>`)
still works, i.e. the project-wide "Allow public access" setting stayed on.
Postgres-Changes delivery of `circle_messages` still reaches B.

### 4.5 Deploy `notify-new-message` and verify the webhook secret

Deployment order matters and is fail-closed:

1. Set the secret (§2.3). The currently deployed function ignores it.
2. Add the webhook header (§4.5.1). The currently deployed function ignores it.
3. Deploy the function.

```bash
supabase functions deploy notify-new-message --project-ref <staging>
supabase functions deploy delete-account   --project-ref <staging>
```

`supabase/config.toml` pins `verify_jwt = false` for `notify-new-message` (its
caller is pg_net, which has no JWT) and `verify_jwt = true` for `delete-account`.

#### 4.5.1 Database Webhook

Dashboard → Integrations → Webhooks → **Create a new hook**:

* Table: `public.circle_messages`
* Events: `INSERT`
* Type: **Supabase Edge Functions** → `notify-new-message`
* HTTP Headers → **Add header** (not "Add secret key"):
  * Name: `x-kaspot-webhook-secret`
  * Value: the same value as `KASPOT_WEBHOOK_SECRET`

`Authorization: Bearer <secret>` is also accepted, for a webhook UI that can only
set that header. The dedicated header wins when both are present.

The webhook stores the header in its trigger definition, so it is visible to
anyone who can read the trigger SQL or a database dump. That is why this secret
grants nothing but this one endpoint.

**Pass:** W1–W2 below, then W3.

| # | Check | How |
|---|---|---|
| W1 | No secret is rejected, nothing sent | `curl -i -X POST <url>/functions/v1/notify-new-message -H 'content-type: application/json' -d '{}'` → `401` |
| W2 | A wrong secret is rejected | same with `-H 'x-kaspot-webhook-secret: wrong'` → `401` |
| W2b | A forged payload cannot aim a push at someone else | send a correct-secret body whose `record.recipient_id` names a third user; the push still goes only to the real recipient (routing is read from the database, not the body) |
| W2c | Unauthenticated requests never touch the database or FCM | function logs show no `message`/`connection`/`token` query for a 401/500 request |

### 4.6 Generic notification content and recipient targeting

**Pass:**

* B's device shows exactly "New message in KaSpot" / "Open KaSpot to view your
  message" — no sender name, no message text, no preview.
* The tap opens the A↔B conversation.
* C (a different pair) receives nothing.
* Turning "Messages & invitations" off for B and sending again produces no push
  (`notifications_disabled` in the log, 200 to the webhook).
* Removing the connection and sending again produces no push (`not_connected`).
* A user with several devices gets one push per device, and a stale token's
  failure is counted in the log without failing the webhook.

### 4.7 Staging Firebase service account and a real FCM delivery

1. Create/select a Firebase project for staging; add the staging Android app.
2. Download the service account JSON; set it as `FIREBASE_SERVICE_ACCOUNT_JSON`
   (§2.3). Never commit it (`*firebase-adminsdk*.json` is ignored).
3. `google-services.json` for the staging package must be the staging one; a
   production `google-services.json` in a staging build delivers pushes into the
   production Firebase project.
4. Install the staging APK on a real device (§7), sign in as B, confirm a token
   row appears in `device_tokens` with `supports_data_only = true`.

**Pass:** the message actually appears on the device, not merely "FCM returned
200"; and Firebase Console → Messaging shows a data-only message carrying
`type/sender_id/message_id/title/body` and nothing else. Then the delete below:

* unset `FIREBASE_SERVICE_ACCOUNT_JSON` in staging only, send a message to a user
  with **no** device tokens → the webhook still returns 200 `no_tokens` (a
  missing push credential must not turn a no-push event into a 500);
* restore the credential.

### 4.8 Deploy `delete-account` and verify the matrix

Call it with A's access token. Expected results:

| Case | Request | Expected |
|---|---|---|
| Success | correct password | `200 {deleted:true}`, A's 11 tables empty |
| Wrong password | wrong password | `403 password_mismatch`, nothing deleted |
| Wrong Google account | ID token of a different Google user | `403 google_mismatch`, nothing deleted |
| Invalid Google token | expired/garbage token | `403 google_token_invalid` |
| No credential | `{}` | `400 credential_required` |
| No token | no `Authorization` header | `401 unauthenticated` |
| Repeat | same call twice | second call ends `200 {deleted:true}` or `401` once the token dies — never a false failure |
| Concurrent | two calls in parallel | one deletes, the other reports success or a cleanup check, never `deletion_failed` for an account that is gone |
| Cleanup failure | simulate with a table missing its cascade on a scratch DB | `500 cleanup_incomplete` with the table names, plus a server log line carrying the user id |

**Pass:** all rows above, and `delete-account`'s log contains no password, no
token, no e-mail.

### 4.9 A deleted account cannot come back

| # | Check | Expected |
|---|---|---|
| D1 | Refresh the deleted session | `400`/`401`, no new access token |
| D2 | Old access token against PostgREST `/profiles`, `/locations`, `/device_tokens` | empty or `401`; `POST /locations` → `401`/`403` |
| D3 | Old token joins `chat-A_B` on Realtime | join denied |
| D4 | All 11 tables hold no row for A's id (run as owner) | 0 rows |
| D5 | A's queued location fix on the device | gone after the app clears the session (§7.4) |

### 4.10 Rollback and recovery

Do not roll back the caller-scope migration to its pre-migration bodies; see §8.
What must be verified is the recovery:

```bash
psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f supabase/migrations/20261024_rpc_caller_scope.sql   # re-apply, must be a no-op
psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f supabase/tests/rollback_drill.sql
psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f supabase/tests/install_contract.sql
```

**Pass:** re-applying the migration twice in a row is idempotent, the drill
passes (it proves the regression is real and that the detector catches it), and
the contract test still passes. Then repeat for the retention migration's own
rollback block (§8.2) on a scratch database, not on staging.

## 5. What the caller-scope migration changes, and why the ACL check matters

Before it, this project's functions were reachable by `anon`. Supabase grants
new functions in `public` to `anon`, `authenticated` and `service_role` through
default privileges, and `revoke ... from public` does **not** remove those direct
grants — so "authenticated only" in the old SQL was not true. Combined with an
`auth.uid() is null` bypass that meant an unauthenticated caller could read the
connection graph.

After it:

* `public.is_accepted_connection` / `public.is_valid_reply` — EXECUTE to
  `authenticated` only; revoked from `public`, `anon` and `service_role`; return
  `false` when the caller has no identity or is not a participant.
* `kaspot_internal.is_connected` / `kaspot_internal.reply_in_conversation` —
  pure facts, EXECUTE to `service_role` only, in a schema no client role can
  use. Trusted server code uses these.

The migration refuses to commit if those privileges are not the result, so a
misconfigured run leaves the database untouched:

```sql
-- run any time to see the effective state
select n.nspname, p.proname,
       has_function_privilege('anon', p.oid, 'EXECUTE')          as anon_ok,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_ok,
       has_function_privilege('service_role', p.oid, 'EXECUTE')  as service_role_ok
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where (n.nspname, p.proname) in (
  ('public','is_accepted_connection'), ('public','is_valid_reply'),
  ('kaspot_internal','is_connected'), ('kaspot_internal','reply_in_conversation'))
order by 1, 2;
```

## 6. Location retention: scheduling the physical purge

The retention window itself needs no scheduler: the SELECT policy hides an
expired row from its owner and from every grantee the instant `expires_at`
passes, and nothing in the app depends on a cleanup job. What is **not**
configured anywhere is the *physical* delete — `delete_expired_locations()`
exists but nothing calls it.

Verified facts about the target environment, to be confirmed on staging before
scheduling (they are stated as expectations, not as tested results):

| Question | Expectation to confirm |
|---|---|
| Is `pg_cron` available? | Yes, available; **not installed** (`pg_available_extensions` shows `pg_cron`, `installed_version` is NULL). |
| Is it enabled? | No. Enabling is a separate approved step (§6.1). |
| Required role | The job's `username` is `postgres` (owner of the function). `delete_expired_locations()` is granted to `postgres` and `service_role` only and to no client role. The username argument must be `NULL`, not the literal role name: pg_cron refuses an explicit name from a non-superuser, even when it is the current user (verified against pg_cron 1.6.4). |
| Function signature | `public.delete_expired_locations() returns integer`, SECURITY DEFINER, `search_path = ''`. |
| Timezone | `cron.timezone` is a server setting that defaults to GMT and cannot be set per job, so the schedule is `*/15 * * * *` — an interval, not a time of day. |
| Wrong database | `cron.schedule_in_database(..., current_database(), NULL)` binds the job to one database, and the script refuses unless `current_database() = 'postgres'` **and** `kaspot.environment = 'staging'`. |
| Repeated execution | Safe. The delete is `delete from public.locations where expires_at <= now()`; a second run returns 0. Overlapping runs are harmless. |
| Failure detection | `cron.job_run_details.status`, plus the backlog query in `supabase/ops/location_cleanup_health.sql` (`expired_still_stored`). |
| Disable | `supabase/ops/staging_location_cleanup_disable.sql`, or `select cron.unschedule('kaspot-location-retention-staging');`. |
| Privilege preservation | Scheduling changes no grants and no policies; the purge stays SECURITY DEFINER and stays off the client surface (contract test C9). |

### 6.1 Enable and schedule (staging only)

```sql
-- 1. extension (approved change, staging only)
create extension if not exists pg_cron with schema extensions;

-- 2. environment marker, so the scheduling script can refuse any other database
alter database postgres set kaspot.environment = 'staging';
-- reconnect, then:
```

```bash
psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f supabase/ops/staging_location_cleanup.sql
```

### 6.2 Verify, then watch

```bash
sleep 900   # let one interval pass
psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f supabase/ops/location_cleanup_health.sql
```

**Pass:** the job row has `schedule = */15 * * * *`, `database = postgres`,
`username = postgres`, `active = t`; at least one `succeeded` run exists;
`failed_runs_last_24h = 0`; `expired_still_stored` is near zero and does not grow
across two checks 15 minutes apart.

**Also verify by deletion, not only by query:** write a location, move its
`expires_at` into the past with the trigger disabled (as
`location_retention.sql` step 5 does), wait one interval, then confirm the row is
**gone** from the table, not merely invisible. That is the only evidence that
physical deletion works.

### 6.3 Operator notes

* `cron.job_run_details` is not pruned automatically. Decide one retention for it
  before production (a weekly delete of rows older than 30 days is enough) and
  record the decision; do not let it grow unbounded.
* A failed run leaves the rows for the next run. There is no retry queue and
  none is needed.
* The purge does not guarantee that a coordinate is unrecoverable from backups.
  Backup retention is a provider setting; if the Privacy Policy ever states a
  deletion window, it has to describe the backup window too.

## 7. Android staging build and physical-device checks

### 7.1 The target guard

`tool/live_check_env.ps1` and the app must agree about which project they are
talking to. The harness now requires `KASPOT_PROJECT_REF`, derives the ref from
`SUPABASE_URL` in `.env`, and refuses both when they disagree and when the target
is production without an explicit `KASPOT_ALLOW_PRODUCTION=1`.

```powershell
$env:KASPOT_PROJECT_REF = '<staging ref>'
$env:SUPABASE_URL       = 'https://<staging ref>.supabase.co'   # same project
$env:SUPABASE_ANON_KEY  = '<staging publishable key>'
# then, for the harness only, a staging service-role key from the dashboard:
#   $env:LIVECHECK_SERVICE_KEY = '<staging service_role key>'
```

### 7.2 Build

```bash
flutter build apk --release \
  --dart-define=KASPOT_BACKEND=staging \
  --dart-define=SUPABASE_URL=https://<staging-ref>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<staging publishable key> \
  --dart-define=KASPOT_ACCOUNT_DELETION=true
```

`--dart-define` **now wins over the bundled `.env`**, which is what makes this
command safe: before this revision `dotenv.maybeGet('SUPABASE_URL')` was read
first, so a staging build with `--dart-define` would still have talked to
production while the build command looked correct. `KASPOT_BACKEND=staging`
additionally makes the app refuse to start against a URL that is not the one
declared for that backend, and refuses production unless
`KASPOT_BACKEND=production` is explicit.

Confirm the build before installing:

```bash
unzip -p build/app/outputs/flutter-apk/app-release.apk assets/flutter_assets/.env | head
# must NOT contain the production ref, or the following must be present:
flutter test test/backend_target_test.dart
```

`KASPOT_ACCOUNT_DELETION=true` is for the staging build **only**. The release
build keeps it absent until §4.8, §4.9 and §7.3 pass on a real device; while it
is absent the Privacy Policy states that in-app deletion is unavailable.

### 7.3 Device matrix (physical device, staging backend)

Separate these results from widget tests. Widget tests exercise the UI flow with
`debugDeleteAccountOverride`; they cannot prove a network path, a real Google
account picker, background tracking teardown, or FCM delivery.

| # | Check | Pass condition |
|---|---|---|
| A1 | Password-based deletion | dialog → password → account gone, signed out |
| A2 | Google-based deletion | native account picker → correct account → account gone |
| A3 | Wrong password | inline error, still signed in, server returned `403 password_mismatch` |
| A4 | Mismatched Google account | inline error, nothing deleted |
| A5 | Airplane mode during deletion | "could not reach the server, nothing was deleted"; still signed in |
| A6 | Server `cleanup_unverified` | "account deleted but cleanup unverified"; device signed out |
| A7 | Local sign-out after deletion | relaunch → welcome screen, no restored session |
| A8 | Queued location fix removed | queue a fix offline (§7.4), delete the account, relaunch → nothing uploaded |
| A9 | Background tracking stops | foreground-service notification gone, no location row appears afterwards |
| A10 | No tracking under another account | sign in as B on the same device → no location write carrying A's fix |
| A11 | Chat and Realtime unaffected for others | B and C keep messaging; B still receives live messages |
| A12 | Push opens the right conversation | tap a push → correct A↔B thread, not a generic inbox |
| A13 | Notification preferences respected | messages off → no push, chat still works |
| A14 | Policy and controls agree | Privacy Policy text matches the deletion control this build exposes |

To make A8 meaningful, queue a fix with the device offline **and** sharing
enabled, then delete the account while still offline (the deletion will fail) and
retry online. The queue lives in `SharedPreferences` under one key and is cleared
by `KaSpotService._clearLocalSession()` on sign-out and after a confirmed
deletion.

## 8. Rollback and recovery

### 8.1 Caller-scope migration — no safe rollback exists

Reverting `20261024` to its pre-migration bodies restores an **authenticated**
connection-graph oracle while every ACL check stays green: the wrapper loses its
`auth.uid()` predicate, and the grant to `authenticated` is what makes it
reachable. `supabase/tests/rollback_drill.sql` demonstrates exactly that.

Use the recovery procedure documented at the bottom of
`20261024_rpc_caller_scope.sql`:

* **A (preferred):** re-apply the migration. It is idempotent and self-checking.
* **B:** if a legitimate caller is failing with `42501`, forward-fix that call
  site — server code uses `kaspot_internal.*`, and a policy must pass
  `auth.uid()` as one of the arguments.
* **C (break-glass only):** change the failing policy to not depend on the
  wrapper. If the bodies must be reverted anyway: time-box it, revoke EXECUTE
  from `authenticated` in the same transaction (an outage is visible, a
  disclosure is not), run the detector continuously, log which sessions reached
  the API, then restore with A.

The detector, also asserted by the contract test:

```sql
select p.oid::regprocedure
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where (n.nspname, p.proname) in (
        ('public','is_accepted_connection'), ('public','is_valid_reply'))
  and pg_get_functiondef(p.oid) !~* 'auth\.uid\(\)';
-- must return zero rows
```

### 8.2 Retention migration

```sql
-- staging / scratch only
drop trigger if exists location_retention_enforcement on public.locations;
drop function if exists public.enforce_location_retention();
drop function if exists public.delete_expired_locations();
drop index if exists public.locations_expires_at_idx;
alter table public.locations
  drop column if exists received_at,
  drop column if exists expires_at;
drop function if exists public.location_retention_interval();
```

That restores the pre-migration read policy only if the old policy is put back
first; until it is, the `locations_authorized_read` policy references a dropped
column and blocks every read. Roll this back on a scratch database, never on
staging while §4 is being verified.

### 8.3 Function and webhook

* Function: redeploy the previous version (`supabase functions deploy <name> --project-ref <staging>`).
* Webhook: remove the custom header, or delete the hook.
* Scheduling: `supabase/ops/staging_location_cleanup_disable.sql`.

## 9. Local checks (no project needed)

```bash
npx deno@2 check --config supabase/functions/deno.json \
  supabase/functions/delete-account/*.ts supabase/functions/notify-new-message/*.ts

npx deno@2 test --allow-env --config supabase/functions/deno.json supabase/functions

flutter analyze
flutter test
```

`--allow-env` is required because importing google-auth-library reads
`process.env` at load time. No unit test in this repository makes a network call.

SQL, without a hosted project (`supabase/tests/harness/`):

```bash
docker run -d --name kaspot-verify-pg --rm -e POSTGRES_PASSWORD=postgres \
  -p 127.0.0.1:54322:5432 public.ecr.aws/supabase/postgres:17.11.0.004
powershell -NoProfile -ExecutionPolicy Bypass \
  -File supabase/tests/harness/run-local-verify.ps1
```

It provisions `auth.uid()` and `realtime.messages` the way the GoTrue and
Realtime services would, then runs `schema.sql` alone, the clean install, the
upgrade path from `HEAD~1`, the idempotency pass and all four suites. The runner
refuses a container that publishes anything but a loopback address, and never
reads `supabase/.temp` or contacts a hosted project. `supabase start` is **not**
used: the full stack pulls nine service images, and none of the SQL under test
needs them.

## 10. Still unresolved (not deployment steps)

* No published privacy contact address; age assurance still undecided. Both are
  stated as gaps in the Privacy Policy rather than papered over.
* Duplicate webhook deliveries are not suppressed server-side (pg_net delivers
  once per INSERT, and the client collapses per-sender notifications into one
  banner). At-most-once would need a delivery-log table and a migration.
* The retention window is a proposed product policy (24 hours), not an approved
  one. `lib/utils/privacy_policy_content.dart` states no window until the
  database value, the scheduled purge and a deployed environment have all been
  verified.
* Backup retention of the hosted provider is unmeasured. A 24-hour row lifetime
  does not imply a 24-hour backup lifetime.

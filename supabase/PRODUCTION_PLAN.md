# Production change plan — prepared, not executed

Nothing in this document has been run. No migration has been applied, no Edge
Function deployed, no cron job scheduled and no account deleted. It is the
sequence to follow once staging (§4 of `supabase/STAGING.md`) has passed and the
change is approved.

Every step has a **verification** and a **stop condition**. A stop condition is
not advice: if it is met, stop, restore the previous state (or leave the step
un-applied) and go back to the plan.

Step labels:

* **[SECURITY]** — changes who can read or write what. Highest risk, verified
  separately, never bundled with anything else.
* **[SCHEMA]** — additive structure change; low risk, still reversible.
* **[DEPLOY]** — Edge Function code, no database change.
* **[CONFIG]** — dashboard/provider setting.
* **[BUILD]** — app binary.

---

## 0. Preconditions (all must be true before step 1)

- [ ] Staging §4.1–§4.10 in `supabase/STAGING.md` passed, on a hosted project,
      with the results recorded.
- [ ] A real-device run passed §7.3 (Android matrix), including background
      tracking teardown and the queued-fix case.
- [ ] The 24-hour retention window has been approved **as a product policy**.
      Until it is, `20261023_location_retention_expiration.sql` does not ship and
      `privacy_policy_content.dart` keeps stating no window.
- [ ] A change window with an owner and a rollback owner is agreed.
- [ ] The production project ref `etuosispxwfmvcupjhkv` is written on the change
      record, and every command in this plan names it explicitly.
- [ ] No other migration, function deploy or dashboard change is running.

**Stop:** any item unticked → do not start.

---

## 1. [CONFIG] Freeze and record

Record, in the change ticket:

* current app version in the stores and the version being released;
* current Edge Function versions (Dashboard → Edge Functions → each function);
* the identity of the person executing each step;
* a timestamped copy of the verification output of steps 3–7.

**Stop:** no named rollback owner → do not start.

---

## 2. [CONFIG] Backup that can actually be restored

1. Take a logical dump:

   ```bash
   pg_dump -Fc --no-owner "$KASPOT_PROD_DIRECT_URL" > kaspot-prod-$(date +%Y%m%dT%H%M).dump
   pg_dump --schema-only --no-owner "$KASPOT_PROD_DIRECT_URL" > kaspot-prod-schema-before.sql
   ```

   Use the **direct** connection string (port 5432), not the pooled one: a pooler
   can time out mid-dump. The dump contains the Database Webhook trigger
   definition, i.e. the webhook header value — treat it as a secret.

2. Confirm the project's automatic backup / PITR state in the Dashboard and
   record the restore point that the provider guarantees.

3. **Prove the dump is restorable** before relying on it: restore into a scratch
   database and run

   ```bash
   psql "$KASPOT_SCRATCH_DATABASE_URL" -v ON_ERROR_STOP=1 \
     -f supabase/tests/install_contract.sql
   ```

   Expect failures (the scratch copy is pre-migration). What matters is that the
   file restored and the contract test could run — a dump that cannot be
   restored is not a backup.

**Stop:** restore into scratch fails, or the provider's restore point is older
than the last deploy → do not proceed; escalate.

---

## 3. [CONFIG] Capture production structure and ACLs, and diff it

Production is **not** assumed to match this repository.

```bash
psql "$KASPOT_PROD_DIRECT_URL" -v ON_ERROR_STOP=1 -c "
  select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args,
         p.prosecdef, p.proacl
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public','kaspot_internal')
  order by 1,2,3;" > prod-acl-before.txt

psql "$KASPOT_PROD_DIRECT_URL" -v ON_ERROR_STOP=1 -c "
  select schemaname, tablename, policyname, cmd, roles
  from pg_policies order by 1,2,3;" > prod-policies-before.txt

psql "$KASPOT_PROD_DIRECT_URL" -v ON_ERROR_STOP=1 -c "
  select tgname, tgrelid::regclass from pg_trigger where not tgisinternal
  order by 2,1;" > prod-triggers-before.txt

psql "$KASPOT_PROD_DIRECT_URL" -v ON_ERROR_STOP=1 \
  -f supabase/tests/install_contract.sql > prod-contract-before.txt 2>&1
```

Then compare `prod-policies-before.txt` and `prod-triggers-before.txt` with what
`schema.sql` produces locally. **Any** policy or trigger in production that this
repository does not define must be understood before step 4 — it may belong to a
dashboard integration, or it may be drift that changes the effect of a migration
below.

**Stop:** a policy, trigger or function exists in production that is not
explained, or `public.locations` does not exist → stop and investigate; do not
"just apply" a migration that assumes a shape.

---

## 4. [SECURITY] Migration 1 — `20261024_rpc_caller_scope.sql`

Why first: it is the only change that rewrites an authorization primitive used
by every RLS policy. Doing it first means a later failure cannot be confused with
it, and its verification is unambiguous.

```bash
psql "$KASPOT_PROD_DIRECT_URL" -v ON_ERROR_STOP=1 \
  -f supabase/migrations/20261024_rpc_caller_scope.sql
```

The file is transactional and **refuses to commit** unless the resulting
privileges are the design, so a partial application is not a state this step can
produce.

Verification immediately after:

```bash
psql "$KASPOT_PROD_DIRECT_URL" -v ON_ERROR_STOP=1 -c "
  select p.oid::regprocedure, has_function_privilege('anon', p.oid, 'EXECUTE') as anon,
         has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth,
         has_function_privilege('service_role', p.oid, 'EXECUTE') as svc
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public','kaspot_internal')
     or p.proname in ('is_accepted_connection','is_valid_reply');"
psql "$KASPOT_PROD_DIRECT_URL" -v ON_ERROR_STOP=1 \
  -f supabase/tests/install_contract.sql
```

Pass: `anon = false` and `auth = true` for the two wrappers; `service_role` holds
the two `kaspot_internal` helpers and not the wrappers; contract test passes.

**Stop:** the contract test reports **C8** (identity predicate missing), or any
wrapper is executable by `anon` → re-apply the migration (it is the recovery),
and if that does not fix it, stop and use the RECOVERY section of the migration —
never re-grant the old bodies.

**Behaviour check while the window is open:** sign in on a device, open the map,
send a message, react to a message, accept a connection request. A wrapper
missing an `auth.uid()` argument fails loudly with `42501` on the first such
action; that is the signal for Recovery B, not for a rollback of the bodies.

---

## 5. [SECURITY] Migration 2 — private chat channel

`20261023_private_chat_channel_authorization.sql`.

This one adds two policies to `realtime.messages`, a table owned by
`supabase_realtime_admin`. It deliberately does **not** enable RLS on that table
(that statement fails with `42501` and would silently skip both policies).

```bash
psql "$KASPOT_PROD_DIRECT_URL" -v ON_ERROR_STOP=1 \
  -f supabase/migrations/20261023_private_chat_channel_authorization.sql
psql "$KASPOT_PROD_DIRECT_URL" -v ON_ERROR_STOP=1 -c "
  select policyname, cmd, roles from pg_policies
  where schemaname='realtime' and tablename='messages' order by 1;"
```

Pass: both `chat_channel_participant_receive` and
`chat_channel_participant_publish` exist, and nothing else on that table changed.

**Compatibility:** the production app build already in the stores opens
`chat-<a>_<b>` and the map channel. The policy matches the two ids in either
order, so an installed build is not locked out of its own conversation. The map
channel is untouched by design.

**Stop:** either policy is missing, or the project-wide Realtime "Allow public
access" setting got turned off → the map channel dies; restore the setting and
re-check.

**Immediately after:** two signed-in test accounts check that a private
conversation still delivers and that the location map still updates. If either
fails, un-deploying these policies (drop both) restores the previous behaviour
and reopens public access to conversation channels — so if it fails, fix forward
within the window rather than leaving it dropped overnight.

---

## 6. [SECURITY] Migration 3 — location retention

`20261023_location_retention_expiration.sql`.

This one backfills `received_at`/`expires_at` and replaces
`locations_authorized_read`. The backfill clamps to `now()`, so a row that has
not been written for longer than the window becomes expired immediately — that
is the intended behaviour and it is the one thing to look at afterwards: users
whose last fix was old will stop seeing that marker.

```bash
psql "$KASPOT_PROD_DIRECT_URL" -v ON_ERROR_STOP=1 \
  -f supabase/migrations/20261023_location_retention_expiration.sql
psql "$KASPOT_PROD_DIRECT_URL" -v ON_ERROR_STOP=1 \
  -f supabase/tests/location_retention.sql
psql "$KASPOT_PROD_DIRECT_URL" -v ON_ERROR_STOP=1 \
  -f supabase/tests/install_contract.sql
```

Password for the maintenance role: the retention test creates fixtures and rolls
them back; run it as the owner, never as a client role.

**Stop:** `location_retention.sql` fails → stop and use its rollback block
(`supabase/STAGING.md` §8.2) on production only with the read policy restored in
the same transaction; otherwise every location read breaks.

**Rollback of this step is the safest of the three** and is available: drop the
trigger, the two functions, the index and the two columns. It does not affect
authorization.

---

## 7. [SCHEMA] Migrations 4 and 5 — additive

```bash
psql ... -f supabase/migrations/20261023_device_token_notification_capability.sql
psql ... -f supabase/migrations/20261020_message_reactions.sql
psql ... -f supabase/migrations/20261020_message_reactions_combined.sql
psql ... -f supabase/migrations/20261020_message_reactions_security_fix.sql
```

* `supports_data_only` is additive and defaults to `false`; every existing token
  keeps receiving the legacy payload it already understands.
* The three reaction files are one feature: `_combined` supersedes the other two
  and `_security_fix` must be last if the separate files are used. All three are
  idempotent, so applying all of them in filename order is safe — but note in the
  change record which ones were already applied in the past, because a project
  that ran only `_combined` will not have the same migration history.

**Stop:** `20261020_*` fails because the base table is missing → production is
older than this repository assumes; go back to step 3, not forward.

---

## 8. [DEPLOY] Edge Functions, in this order

1. Set the secrets (Dashboard → Edge Functions → Secrets, or
   `supabase secrets set --project-ref etuosispxwfmvcupjhkv …`):
   `KASPOT_WEBHOOK_SECRET` (new, 64 hex), `GOOGLE_WEB_CLIENT_ID`,
   `FIREBASE_SERVICE_ACCOUNT_JSON` (production service account).
   The currently deployed webhook function ignores all three.
2. Update the Database Webhook header to the new secret
   (`x-kaspot-webhook-secret`). The currently deployed function ignores it.
3. Deploy:

   ```bash
   supabase functions deploy notify-new-message --project-ref etuosispxwfmvcupjhkv
   supabase functions deploy delete-account   --project-ref etuosispxwfmvcupjhkv
   ```

Do not reorder: deploying `notify-new-message` before the header exists makes it
reject every webhook (401) — fail-closed, but it stops notifications until the
header is saved. Doing the header first has no effect on the old function.

`delete-account` is deployed but **not reachable from the app** until step 10:
`ReleaseFlags.accountDeletionEnabled` is false in every build produced without
the flag.

**Verification:**

| Check | Expected |
|---|---|
| `POST /functions/v1/notify-new-message` with no secret | 401 |
| same with a wrong secret | 401 |
| a real message between two connections | one generic push arrives, tap opens the thread |
| Firebase Console → Messaging record | data-only payload, no message text, no sender name |
| `POST /functions/v1/delete-account` with no Authorization | 401 |
| with a valid token and a wrong password, on a **disposable** account | 403 `password_mismatch`, account still exists |

**Stop:** a 200 on the no-secret request → the deployed function is not the
version in this repository; stop and re-deploy.
**Stop:** pushes do not arrive → check the webhook header value and the function
log for `server_configuration` before changing anything else.

### Rotating the secret later

Set the new secret first, then update the header immediately. Between the two
there is a short window of 401s (`unauthorized`) and therefore no notifications.
A zero-downtime rotation needs a function that accepts two secrets; that is not
implemented, and is listed as a decision in §12.

---

## 9. [CONFIG] Retention scheduling and monitoring

Prerequisite: the window is approved (step 0) and step 6 passed.

```sql
-- production, explicitly, after approval
create extension if not exists pg_cron with schema extensions;
alter database postgres set kaspot.environment = 'production';  -- marker, not 'staging'
```

The scheduling script in `supabase/ops/` refuses any database that is not marked
`staging`. That guard is deliberate: production scheduling is a separate,
explicitly reviewed action, and re-using the staging script by flipping the
marker is exactly the mistake it is designed to prevent. Schedule production with
the reviewed statement below, in the change window, and record the job id:

```sql
select cron.schedule_in_database(
  'kaspot-location-retention',
  '*/15 * * * *',
  'select public.delete_expired_locations();',
  'postgres',
  NULL   -- see below: an explicit role name is refused for a non-superuser
);
```

The last argument must be `NULL`, not `'postgres'`. pg_cron rejects an explicit
role with "must be superuser to create a job for another role" even when the
name equals the current user (verified against pg_cron 1.6.4). `NULL` records the
creating role, which is `postgres` when this is run from the SQL editor; confirm
it with the `username` column of `cron.job`.

Then, after at least one interval:

```bash
psql "$KASPOT_PROD_DIRECT_URL" -v ON_ERROR_STOP=1 -f supabase/ops/location_cleanup_health.sql
```

Pass: `active = t`, schedule and database as above, at least one `succeeded` run,
`failed_runs_last_24h = 0`, `expired_still_stored` near zero and not growing
between two checks.

**Stop:** the job exists but no run appears after two intervals → check
`cron.job_run_details` for an error, and unschedule rather than leaving a job
that silently does nothing:
`select cron.unschedule('kaspot-location-retention');`

**Monitoring:** the Supabase Cron dashboard shows run history; `job_run_details`
is not pruned automatically, so agree a retention for it (a weekly delete of rows
older than 30 days is enough) and record it. Alert on `failed_runs_last_24h > 0`
and on `expired_still_stored` growing for more than an hour.

**Stop:** if pg_cron cannot be installed on this project → do not invent a
substitute scheduler in the app. Leave the purge manual, record it, and keep the
policy-based invisibility (which is what actually enforces the window).

---

## 10. [BUILD] Account deletion enablement

Only after steps 4–8 passed and a real-device run on staging covered §7.3:

```bash
flutter build appbundle --release \
  --dart-define=KASPOT_BACKEND=production \
  --dart-define=SUPABASE_URL=https://etuosispxwfmvcupjhkv.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<production publishable key> \
  --dart-define=KASPOT_ACCOUNT_DELETION=true
```

* `KASPOT_BACKEND=production` is required: the deletion flag is ignored without a
  verified target, and the build refuses to start if the URL is not production.
* The Privacy Policy content is generated from
  `ReleaseFlags.accountDeletionEnabled`, so the same build that shows the button
  also states that deletion is available. Verify both on the store build.
* The Play Store data-deletion declaration and the privacy policy URL must
  already describe the in-app path before this build is submitted.

**Stop:** the deletion button appears in a build whose `KASPOT_BACKEND` is not
production → do not publish; the binary is mis-targeted.

**Stop:** deletion fails in the store build for any of the §4.8 cases → ship a
build with the flag off (the backend stays deployed and harmless) and fix
forward.

---

## 11. [CONFIG] Verification and close-out

Run, in this order, and attach the output to the change record:

1. `install_contract.sql` → passes.
2. `rpc_caller_scope.sql`, `chat_channel_authorization.sql`,
   `location_retention.sql`, `rollback_drill.sql` → pass (each rolls back).
   These create fixtures: run them as the owner, on production, only inside the
   change window.
3. `location_cleanup_health.sql` → as in step 9.
4. A real push delivered to a real device, and a tap opening the right thread.
5. A real message, a reaction, a connection accept, a sharing toggle — the four
   write paths that go through the rewritten helpers.
6. `delete-account` exercised end-to-end on a **disposable** production account
   created for the check, then confirm: token refresh fails, old token gets
   nothing from `/profiles`, and the 11 tables hold no row for it.

**Stop:** any of 1–3 fails → the change is not complete; follow §11 of
`supabase/STAGING.md` (recovery), not a rollback of the function bodies.

---

## 12. Decisions still open (not steps)

1. **Retention window** — 24 hours is a proposal. It is mirrored in
   `public.location_retention_interval()` and
   `LocationTrackingConfig.retention`; changing one without the other makes the
   app queue fixes the server refuses.
2. **Duplicate reaction migrations** — three files describe one feature. Decide
   whether `20261020_message_reactions_combined.sql` stays in the directory; a
   project that applied only `_combined` and one that applied the other two have
   different histories but the same schema.
3. **Zero-downtime webhook rotation** — needs a function that accepts a current
   and a previous secret.
4. **Backup retention** — a 24-hour row lifetime does not imply a 24-hour backup
   lifetime. If the policy ever states a deletion window, it must describe the
   backup window the provider actually holds.
5. **Privacy contact address and age assurance** — still gaps, stated as gaps in
   the policy.
6. **Local secret material** — `kaspot-8cbfb-firebase-adminsdk-*.json`,
   `Supabase Pass.txt`, `client_secret_*.json` and `google-services.json` exist on
   the development machine and are ignored by git. Decide whether they stay
   there; they must never be used for staging checks.

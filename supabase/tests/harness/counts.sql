-- Duplicate detection across the whole database, independent of the contract
-- test's expected-object list: if a migration re-created something under a new
-- name instead of replacing it, these counts are non-zero.
select 'duplicate_object_names' as check,
       (select count(*) from (
          select schemaname, tablename, policyname
          from pg_policies
          group by 1,2,3 having count(*) > 1) p)
     + (select count(*) from (
          select tgrelid, tgname from pg_trigger where not tgisinternal
          group by 1,2 having count(*) > 1) t)
     + (select count(*) from (
          select n.nspname, p.proname, p.pronargs
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname in ('public','kaspot_internal')
          group by 1,2,3 having count(*) > 1) f) as duplicates;

select
  (select count(*) from pg_policies where schemaname = 'public')   as public_policies,
  (select count(*) from pg_policies where schemaname = 'realtime') as realtime_policies,
  (select count(*) from pg_trigger where not tgisinternal)         as triggers,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public','kaspot_internal'))              as functions;

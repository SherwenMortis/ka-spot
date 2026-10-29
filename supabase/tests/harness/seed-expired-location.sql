-- Prepare one row that is already past its deadline, so the scheduled purge has
-- something to remove. Same trigger-disable trick the retention suite uses, and
-- for the same reason: the trigger rewrites expires_at on every update.
insert into public.locations (user_id, latitude, longitude)
values ('33333333-3333-4333-8333-333333333333', 1.5, 2.5)
on conflict (user_id) do nothing;

alter table public.locations disable trigger location_retention_enforcement;
update public.locations
   set expires_at = now() - interval '1 minute'
 where user_id = '33333333-3333-4333-8333-333333333333';
alter table public.locations enable trigger location_retention_enforcement;

select count(*) as expired_rows_ready
from public.locations where expires_at <= now();

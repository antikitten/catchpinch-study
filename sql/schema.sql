-- catchpinch booking system: database schema
-- run once in the Supabase SQL editor, in this order.

-- slots: the times you offer. no personal data, ever.
create table slots (
    id                bigint generated always as identity primary key,
    starts_at         timestamptz not null,          -- UTC, shown as Europe/London
    duration_minutes  integer     not null default 60,
    status            text        not null default 'open'
                      check (status in ('open', 'blocked')),
    created_at        timestamptz not null default now()
);

-- bookings: one active row per slot and per code; cancelled rows kept for history.
create table bookings (
    id          bigint      generated always as identity primary key,
    slot_id     bigint      not null references slots(id) on delete restrict,
    code        text        not null,                -- Qualtrics ResponseID
    status      text        not null default 'active'
                check (status in ('active', 'cancelled')),
    created_at  timestamptz not null default now()
);

create unique index one_active_booking_per_slot
    on bookings (slot_id)
    where status = 'active';

create unique index one_active_booking_per_code
    on bookings (code)
    where status = 'active';

-- read side: two code-free views the calendar reads from.

-- one row per offered slot: what a single day's time-picker reads.
create or replace view slot_availability as
select
    s.id                as slot_id,
    s.starts_at,
    s.duration_minutes,
    (b.id is not null)  as is_booked,
    (b.id is null
     and s.starts_at > now() + interval '24 hours') as is_bookable
from slots s
left join bookings b
    on b.slot_id = s.id
    and b.status = 'active'
where s.status = 'open';

-- one row per day, in London time: the numbers the colour-coding reads.
create or replace view day_availability as
select
    (s.starts_at at time zone 'Europe/London')::date as day,
    count(*)                                          as total_slots,
    count(*) filter (where b.id is not null)          as booked_slots,
    count(*) filter (
        where b.id is null
        and s.starts_at > now() + interval '24 hours'
    )                                                 as bookable_slots
from slots s
left join bookings b
    on b.slot_id = s.id
    and b.status = 'active'
where s.status = 'open'
group by (s.starts_at at time zone 'Europe/London')::date;

-- security: seal the base tables, expose only the views.
alter table slots    enable row level security;
alter table bookings enable row level security;

revoke all on slots    from anon, authenticated;
revoke all on bookings from anon, authenticated;

grant select on slot_availability to anon, authenticated;
grant select on day_availability  to anon, authenticated;

-- booking function: the single, controlled way anything gets written.
create or replace function book_slot(p_code text, p_slot_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_slot slots%rowtype;
begin
    if p_code is null or length(trim(p_code)) = 0 then
        return jsonb_build_object('ok', false, 'reason', 'missing_code');
    end if;

    select * into v_slot from slots where id = p_slot_id for update;

    if not found then
        return jsonb_build_object('ok', false, 'reason', 'no_such_slot');
    end if;
    if v_slot.status <> 'open' then
        return jsonb_build_object('ok', false, 'reason', 'slot_not_open');
    end if;
    if v_slot.starts_at <= now() + interval '24 hours' then
        return jsonb_build_object('ok', false, 'reason', 'too_soon');
    end if;
    if exists (select 1 from bookings
               where slot_id = p_slot_id and status = 'active') then
        return jsonb_build_object('ok', false, 'reason', 'slot_taken');
    end if;
    if exists (select 1 from bookings
               where code = p_code and status = 'active') then
        return jsonb_build_object('ok', false, 'reason', 'already_booked');
    end if;

    insert into bookings (slot_id, code, status)
    values (p_slot_id, p_code, 'active');

    return jsonb_build_object('ok', true,
                              'slot_id', v_slot.id,
                              'starts_at', v_slot.starts_at);
exception
    when unique_violation then
        return jsonb_build_object('ok', false, 'reason', 'race_lost');
end;
$$;

revoke all on function book_slot(text, bigint) from public;
grant execute on function book_slot(text, bigint) to anon, authenticated;
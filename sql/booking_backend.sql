-- ============================================================================
-- catchpinch booking backend  (Supabase / Postgres, public schema)
--
-- NOTE: the slots and bookings TABLES are not recreated here.
-- This is the logic layer only:
--   - slots      (id bigint, starts_at timestamptz, duration_minutes int,
--                 status text  -- 'open' etc.)
--   - bookings   (id, slot_id -> slots.id, code text, status text  -- 'active'
--                 / 'cancelled', group_flag text  -- 'group_a'/'group_b',
--                 ptx_no ...)
--
-- Running this whole file is safe: every object uses create-or-replace, and the
-- views keep their existing anon grants.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Lead-time rule, defined once so the booking function and the two availability
-- views can never disagree about whether a slot is far enough ahead to book.
-- Slots starting before 11:00 London time need 12 hours' notice (this covers
-- the 09:00 and 10:00 starts); every later slot needs 1 hour.
-- ----------------------------------------------------------------------------
create or replace function public.slot_lead_ok(p_starts_at timestamptz)
returns boolean
language sql
stable
set search_path = public
as $$
    select p_starts_at > now() +
        case
            when (p_starts_at at time zone 'Europe/London')::time < time '11:00'
                then interval '12 hours'
            else interval '1 hour'
        end;
$$;

grant execute on function public.slot_lead_ok(timestamptz) to anon;


-- ----------------------------------------------------------------------------
-- Per-slot availability, read by the booking page's day view.
-- ----------------------------------------------------------------------------
create or replace view public.slot_availability as
select s.id as slot_id,
       s.starts_at,
       s.duration_minutes,
       (b.id is not null) as is_booked,
       ((b.id is null) and slot_lead_ok(s.starts_at)) as is_bookable
from slots s
left join bookings b on b.slot_id = s.id and b.status = 'active'
where s.status = 'open';


-- ----------------------------------------------------------------------------
-- Per-day counts, read by the booking page's month grid.
-- ----------------------------------------------------------------------------
create or replace view public.day_availability as
select ((s.starts_at at time zone 'Europe/London'))::date as day,
       count(*) as total_slots,
       count(*) filter (where b.id is not null) as booked_slots,
       count(*) filter (where (b.id is null) and slot_lead_ok(s.starts_at))
           as bookable_slots
from slots s
left join bookings b on b.slot_id = s.id and b.status = 'active'
where s.status = 'open'
group by ((s.starts_at at time zone 'Europe/London'))::date;


-- ----------------------------------------------------------------------------
-- book_slot: the one write path for making a booking. Runs as SECURITY DEFINER
-- so the anonymous page can call it, locks the slot row so two people racing for
-- the same time serialise, and refuses a booking that the experiment runner
-- would later reject (missing/invalid group_flag). Returns {ok:true,...} or
-- {ok:false, reason:'...'}.
-- ----------------------------------------------------------------------------
create or replace function public.book_slot(
    p_code text,
    p_slot_id bigint,
    p_group_flag text
)
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
    if p_group_flag is null or p_group_flag not in ('group_a', 'group_b') then
        return jsonb_build_object('ok', false, 'reason', 'missing_group');
    end if;

    -- lock this slot row so two people racing for it serialise here
    select * into v_slot from slots where id = p_slot_id for update;

    if not found then
        return jsonb_build_object('ok', false, 'reason', 'no_such_slot');
    end if;
    if v_slot.status <> 'open' then
        return jsonb_build_object('ok', false, 'reason', 'slot_not_open');
    end if;
    if not slot_lead_ok(v_slot.starts_at) then
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

    insert into bookings (slot_id, code, status, group_flag)
    values (p_slot_id, p_code, 'active', p_group_flag);

    return jsonb_build_object('ok', true,
                              'slot_id', v_slot.id,
                              'starts_at', v_slot.starts_at);
exception
    when unique_violation then
        -- a race the checks above didn't catch; the unique indexes backstop it
        return jsonb_build_object('ok', false, 'reason', 'race_lost');
end;
$$;

grant execute on function public.book_slot(text, bigint, text) to anon;
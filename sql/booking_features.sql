-- ============================================================================
-- catchpinch booking page: two new features
--   1. look up / cancel an existing booking (for the returning-participant view)
--   2. a "report a problem" form that logs to a table
--
-- Run this whole block in the Supabase SQL editor. Everything is
-- create-or-replace / if-not-exists, so it is safe to run more than once.
--
-- A cancellation is a SOFT cancel: the booking row is flipped from 'active' to
-- 'cancelled', which frees the slot instantly (the availability views only
-- count 'active' bookings), while keeping the record. If your bookings.status
-- column has a CHECK constraint that only allows 'active', the UPDATE will
-- error; tell me and it's a one-line fix to allow 'cancelled' too.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- my_booking: does this code have an active booking, and if so, when?
-- Lets the page greet a returning participant with their existing slot.
-- ----------------------------------------------------------------------------
create or replace function public.my_booking(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_slot slots%rowtype;
begin
    if p_code is null or length(trim(p_code)) = 0 then
        return jsonb_build_object('booked', false);
    end if;

    select s.* into v_slot
    from bookings b
    join slots s on s.id = b.slot_id
    where b.code = p_code and b.status = 'active'
    limit 1;

    if not found then
        return jsonb_build_object('booked', false);
    end if;

    return jsonb_build_object('booked', true,
                              'slot_id', v_slot.id,
                              'starts_at', v_slot.starts_at);
end;
$$;

grant execute on function public.my_booking(text) to anon;


-- ----------------------------------------------------------------------------
-- cancel_booking: cancel this code's active booking, freeing the slot.
-- Verifies by the person's own code, the same trust model as book_slot.
-- ----------------------------------------------------------------------------
create or replace function public.cancel_booking(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_booking bookings%rowtype;
begin
    if p_code is null or length(trim(p_code)) = 0 then
        return jsonb_build_object('ok', false, 'reason', 'missing_code');
    end if;

    -- lock the row so a cancel and a concurrent booking can't tangle
    select * into v_booking
    from bookings
    where code = p_code and status = 'active'
    for update;

    if not found then
        return jsonb_build_object('ok', false, 'reason', 'no_booking');
    end if;

    update bookings set status = 'cancelled' where id = v_booking.id;

    return jsonb_build_object('ok', true, 'slot_id', v_booking.slot_id);
end;
$$;

grant execute on function public.cancel_booking(text) to anon;


-- ----------------------------------------------------------------------------
-- Reports table + writer. RLS is on with no policies, so the anon key can't
-- read or write it directly; the only way in is the SECURITY DEFINER function
-- below. You read the reports from the Supabase dashboard (Table editor) or
-- with the service key.
-- ----------------------------------------------------------------------------
create table if not exists public.bug_reports (
    id          bigint generated always as identity primary key,
    created_at  timestamptz not null default now(),
    code        text,          -- the participant code, if the page had one
    message     text not null
);

alter table public.bug_reports enable row level security;

create or replace function public.report_problem(p_code text, p_message text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_message is null or length(trim(p_message)) = 0 then
        return jsonb_build_object('ok', false, 'reason', 'empty');
    end if;

    insert into public.bug_reports (code, message)
    values (nullif(trim(coalesce(p_code, '')), ''),
            left(trim(p_message), 4000));   -- cap the length defensively

    return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.report_problem(text, text) to anon;
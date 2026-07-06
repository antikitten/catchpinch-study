-- set_ptx_no (v2): assign a unique 4-digit PtxNo AND return the booking's
-- group flag in the same call, so the runner gets both in one round trip.
-- Replaces the earlier version (create or replace updates it in place).
create or replace function set_ptx_no(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_booking bookings%rowtype;
    v_candidate integer;
    v_attempts integer := 0;
begin
    if p_code is null or length(trim(p_code)) = 0 then
        return jsonb_build_object('ok', false, 'reason', 'missing_code');
    end if;

    select * into v_booking
    from bookings
    where code = p_code and status = 'active'
    for update;

    if not found then
        return jsonb_build_object('ok', false, 'reason', 'no_such_booking');
    end if;

    -- Idempotent: if a number is already assigned, return it (and the flag).
    if v_booking.ptx_no is not null then
        return jsonb_build_object('ok', true, 'ptx_no', v_booking.ptx_no,
                                  'group_flag', v_booking.group_flag,
                                  'reused', true);
    end if;

    loop
        v_attempts := v_attempts + 1;
        v_candidate := 1000 + floor(random() * 9000)::int;
        exit when not exists (select 1 from bookings where ptx_no = v_candidate);
        if v_attempts >= 200 then
            return jsonb_build_object('ok', false, 'reason', 'no_free_number');
        end if;
    end loop;

    update bookings set ptx_no = v_candidate where id = v_booking.id;

    return jsonb_build_object('ok', true, 'ptx_no', v_candidate,
                              'group_flag', v_booking.group_flag,
                              'reused', false);
exception
    when unique_violation then
        return jsonb_build_object('ok', false, 'reason', 'race_lost');
end;
$$;
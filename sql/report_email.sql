-- ============================================================================
-- Email the research team whenever a participant submits a problem report.
--
-- How it works: a trigger on the bug_reports table fires an email through
-- pg_net -> Resend each time a row is inserted. It runs asynchronously, so it
-- never slows down or blocks the report itself. The report is ALWAYS saved to
-- the table; the email is a best-effort extra (if it fails, the row is still
-- there, so nothing is ever lost).
--
-- ONE-TIME SETUP, in order:
--   1. Run this whole file in the Supabase SQL editor.
--   2. Put your Resend API key into Supabase Vault, so it never appears in code
--      or in a chat:
--        Dashboard -> Project Settings -> Vault   (or Database -> Vault)
--        -> New secret:  Name = resend_api_key ,  Secret = your re_... key
--      (If you'd rather do it in SQL, run once, with your real key:
--         select vault.create_secret('re_your_key_here', 'resend_api_key');   )
--   3. Submit a test report on the booking page. You should get an email.
--
-- If no key is in the Vault yet, reports still save; they just won't email until
-- the key is added.
-- ============================================================================

-- lets Postgres make outbound HTTP calls (Supabase supports this extension)
create extension if not exists pg_net;

create or replace function public.notify_report()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_key  text;
    v_msg  text;
    v_code text;
begin
    -- read the Resend key from the Vault (never hard-coded here)
    select decrypted_secret into v_key
    from vault.decrypted_secrets
    where name = 'resend_api_key'
    limit 1;

    -- no key configured yet: keep the row, skip the email
    if v_key is null then
        return new;
    end if;

    -- escape the participant's text so it can't break the email's HTML
    v_msg := replace(
                replace(replace(replace(coalesce(new.message, ''),
                    '&', '&amp;'), '<', '&lt;'), '>', '&gt;'),
                chr(10), '<br>');
    v_code := replace(replace(replace(coalesce(new.code, '(none)'),
                '&', '&amp;'), '<', '&lt;'), '>', '&gt;');

    -- send it. The browser User-Agent is there because Resend sits behind
    -- Cloudflare, which blocks requests that don't look like a normal client.
    perform net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object(
            'Authorization', 'Bearer ' || v_key,
            'Content-Type', 'application/json',
            'User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36'
        ),
        body := jsonb_build_object(
            'from', 'catchpinch study <noreply@catchpinchresearch.com>',
            'to', jsonb_build_array('axc103@student.bham.ac.uk'),
            'subject', 'catchpinch: a participant reported a problem',
            'html',
                '<p>A problem was reported on the booking page.</p>'
                || '<p><strong>Participant code:</strong> ' || v_code || '</p>'
                || '<p><strong>Message:</strong><br>' || v_msg || '</p>'
                || '<p style="color:#888;font-size:12px;">'
                || to_char(new.created_at at time zone 'Europe/London',
                           'DD Mon YYYY, HH24:MI') || ' (London)</p>'
        )
    );

    return new;
end;
$$;

drop trigger if exists trg_notify_report on public.bug_reports;
create trigger trg_notify_report
    after insert on public.bug_reports
    for each row execute function public.notify_report();
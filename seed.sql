-- =====================================================
-- SEED DATA (run SECOND, only ONCE, after schema.sql)
-- Makes: rules, 2 semesters, 1 staff, 6 test scholars
-- All passwords: Password123!
-- =====================================================

-- 1) THE RULES (policy)
insert into public.programs (name, max_gwa, min_units, max_failed, max_inc, max_dropped) values
  ('Merit Scholar',     1.75, 18, 0, 0, 0),
  ('Community Scholar', 2.25, 15, 0, 0, 1);

-- 2) SEMESTERS + DEADLINES (Manila time = +08)
insert into public.terms (label, deadline) values
  ('1st Sem AY 2026-2027', '2026-10-30 17:00:00+08'),
  ('2nd Sem AY 2026-2027', '2027-03-30 17:00:00+08');

-- 3) LOGIN USERS + PROFILES
do $$
declare
  r record;
  uid uuid;
begin
  for r in
    select * from (values
      ('staff@test.com', 'Staff Reviewer', 'staff',   'S00'),
      ('a01@test.com',   'Student A01',    'scholar', 'A01'),
      ('a02@test.com',   'Student A02',    'scholar', 'A02'),
      ('a03@test.com',   'Student A03',    'scholar', 'A03'),
      ('a04@test.com',   'Student A04',    'scholar', 'A04'),
      ('a05@test.com',   'Student A05',    'scholar', 'A05'),
      ('a06@test.com',   'Student A06',    'scholar', 'A06')
    ) as t(email, full_name, role, student_no)
  loop
    uid := gen_random_uuid();

    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change, email_change_token_new)
    values (
      '00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated',
      r.email, crypt('Password123!', gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}', '{}', now(), now(),
      '', '', '', '');

    insert into auth.identities (
      id, user_id, provider_id, identity_data, provider,
      last_sign_in_at, created_at, updated_at)
    values (
      gen_random_uuid(), uid, uid::text,
      jsonb_build_object('sub', uid::text, 'email', r.email),
      'email', now(), now(), now());

    insert into public.profiles (id, full_name, email, student_no, role)
    values (uid, r.full_name, r.email, r.student_no, r.role);
  end loop;
end $$;

-- 4) STAFF ASSIGNS PROGRAMS
update public.profiles set program_id = (select id from public.programs where name = 'Merit Scholar')
 where student_no in ('A01', 'A02', 'A05');
update public.profiles set program_id = (select id from public.programs where name = 'Community Scholar')
 where student_no in ('A03', 'A04', 'A06');

-- 5) THE 6 TEST SUBMISSIONS (1st Sem)
insert into public.submissions
  (scholar_id, term_id, program_id, gwa, units, failed, inc, dropped,
   proof_path, submitted_at, verify_status, verified_at)
select p.id, t.id, p.program_id, v.gwa, v.units, v.failed, v.inc, v.dropped,
       null, v.submitted_at::timestamptz, v.vstatus,
       case when v.vstatus = 'verified' then now() end
from (values
  ('A01', 1.75, 18, 0, 0, 0, '2026-10-30 17:00:00+08', 'verified'),  -- exactly at deadline
  ('A02', 1.76, 18, 0, 0, 0, '2026-10-28 10:00:00+08', 'verified'),
  ('A03', 2.25, 15, 0, 0, 1, '2026-10-27 10:00:00+08', 'verified'),
  ('A04', 2.25, 14, 0, 1, 0, '2026-10-26 10:00:00+08', 'verified'),
  ('A05', 1.50, 18, 1, 0, 0, '2026-10-30 17:01:00+08', 'verified'),  -- 1 minute late
  ('A06', 2.00, 15, 0, 0, 0, '2026-10-25 09:00:00+08', 'pending')    -- not verified
) as v(sno, gwa, units, failed, inc, dropped, submitted_at, vstatus)
join public.profiles p on p.student_no = v.sno
join public.terms t on t.label = '1st Sem AY 2026-2027';

-- 6) HISTORY + RUN THE RULE CHECK ON VERIFIED ONES
select public.log_action(id, scholar_id, 'submitted', 'Seed test record') from public.submissions;
select public.log_action(id, scholar_id, 'verified',  'Seed test record')
  from public.submissions where verify_status = 'verified';
select public.run_check(id) from public.submissions where verify_status = 'verified';

-- 7) LOOK AT RESULT (should match the expected column)
select p.student_no, s.gwa, s.units, s.failed, s.inc, s.dropped,
       s.verify_status, s.compliance, s.is_late, s.reasons
from public.submissions s join public.profiles p on p.id = s.scholar_id
order by p.student_no;

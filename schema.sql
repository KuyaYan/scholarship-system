-- =====================================================
-- SCHOLARSHIP RENEWAL SYSTEM - DATABASE (run FIRST)
-- Paste all of this in Supabase > SQL Editor > Run
-- =====================================================

-- ---------- TABLES ----------

-- Rules live HERE (not in JavaScript)
create table public.programs (
  id uuid primary key default gen_random_uuid(),
  name text unique not null,
  max_gwa numeric(3,2) not null,
  min_units int not null,
  max_failed int not null,
  max_inc int not null,
  max_dropped int not null
);

-- One row per semester, with its deadline
create table public.terms (
  id uuid primary key default gen_random_uuid(),
  label text unique not null,
  deadline timestamptz not null
);

-- One row per person (scholar or staff). Same id as login user.
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  email text,
  student_no text unique,
  role text not null check (role in ('scholar','staff')),
  program_id uuid references public.programs(id)
);

-- One row per scholar per semester
create table public.submissions (
  id uuid primary key default gen_random_uuid(),
  scholar_id uuid not null references public.profiles(id) on delete cascade,
  term_id uuid not null references public.terms(id),
  program_id uuid not null references public.programs(id),
  gwa numeric(3,2) not null check (gwa between 1.00 and 5.00),
  units int not null check (units >= 0),
  failed int not null default 0 check (failed >= 0),
  inc int not null default 0 check (inc >= 0),
  dropped int not null default 0 check (dropped >= 0),
  proof_path text,
  submitted_at timestamptz not null default now(),
  verify_status text not null default 'pending'
    check (verify_status in ('pending','verified','rejected')),
  verify_note text,
  verified_by uuid,
  verified_at timestamptz,
  compliance text not null default 'not_checked'
    check (compliance in ('not_checked','compliant','deficient')),
  reasons text,
  is_late boolean,
  decision text not null default 'none'
    check (decision in ('none','approved','held')),
  decision_note text,
  unique (scholar_id, term_id)          -- ONE submit per semester (DB lock)
);

-- Every change is written here
create table public.audit_log (
  id bigint generated always as identity primary key,
  submission_id uuid references public.submissions(id) on delete set null,
  scholar_id uuid references public.profiles(id) on delete cascade,
  actor_id uuid,
  actor_name text,
  action text not null,
  note text,
  created_at timestamptz not null default now()
);

-- ---------- HELPER: is this person staff? ----------
create or replace function public.is_staff()
returns boolean language sql security definer stable
set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role = 'staff');
$$;

-- ---------- LOCK THE DOORS (Row Level Security) ----------
alter table public.programs    enable row level security;
alter table public.terms       enable row level security;
alter table public.profiles    enable row level security;
alter table public.submissions enable row level security;
alter table public.audit_log   enable row level security;

-- Everyone logged in can read rules and semesters
create policy "read programs" on public.programs for select to authenticated using (true);
create policy "read terms"    on public.terms    for select to authenticated using (true);

-- Scholar sees ONLY own rows. Staff sees ALL.
create policy "read profiles" on public.profiles
  for select to authenticated using (id = auth.uid() or public.is_staff());
create policy "read submissions" on public.submissions
  for select to authenticated using (scholar_id = auth.uid() or public.is_staff());
create policy "read audit" on public.audit_log
  for select to authenticated using (scholar_id = auth.uid() or public.is_staff());

-- NO insert / update / delete policies on purpose.
-- Nobody can write straight to tables. Writes only go through the
-- functions below, and those functions check who you are.

-- ---------- INTERNAL FUNCTIONS (not callable from browser) ----------
create or replace function public.log_action(
  p_sub uuid, p_scholar uuid, p_action text, p_note text)
returns void language plpgsql security definer
set search_path = public as $$
declare v_name text;
begin
  select full_name into v_name from public.profiles where id = auth.uid();
  insert into public.audit_log (submission_id, scholar_id, actor_id, actor_name, action, note)
  values (p_sub, p_scholar, auth.uid(), coalesce(v_name, 'system'), p_action, p_note);
end $$;

-- The rule checker. Reads rules from the programs table.
create or replace function public.run_check(p_id uuid)
returns void language plpgsql security definer
set search_path = public as $$
declare
  s public.submissions%rowtype;
  pr public.programs%rowtype;
  t public.terms%rowtype;
  why text[] := '{}';
  late boolean;
begin
  select * into s from public.submissions where id = p_id;
  if not found then raise exception 'Submission not found'; end if;
  if s.verify_status <> 'verified' then
    raise exception 'Blocked: proof is not verified yet';
  end if;

  select * into pr from public.programs where id = s.program_id;
  select * into t  from public.terms    where id = s.term_id;

  late := s.submitted_at > t.deadline;   -- exactly at deadline = on time

  if s.gwa > pr.max_gwa then
    why := why || format('GWA %s is higher than the %s limit', s.gwa, pr.max_gwa); end if;
  if s.units < pr.min_units then
    why := why || format('Units %s is below the %s minimum', s.units, pr.min_units); end if;
  if s.failed > pr.max_failed then
    why := why || format('Failed subjects %s (max allowed %s)', s.failed, pr.max_failed); end if;
  if s.inc > pr.max_inc then
    why := why || format('Incomplete subjects %s (max allowed %s)', s.inc, pr.max_inc); end if;
  if s.dropped > pr.max_dropped then
    why := why || format('Dropped subjects %s (max allowed %s)', s.dropped, pr.max_dropped); end if;
  if late then
    why := why || 'Submitted after the deadline'; end if;

  update public.submissions
     set is_late = late,
         compliance = case when cardinality(why) = 0 then 'compliant' else 'deficient' end,
         reasons = nullif(array_to_string(why, '; '), ''),
         decision = 'none',
         decision_note = null
   where id = p_id;

  perform public.log_action(p_id, s.scholar_id, 'rules_checked',
          coalesce(nullif(array_to_string(why, '; '), ''), 'All rules met'));
end $$;

revoke execute on function public.log_action(uuid, uuid, text, text) from public, anon, authenticated;
revoke execute on function public.run_check(uuid) from public, anon, authenticated;

-- ---------- FUNCTIONS THE WEBSITE CALLS ----------

-- STAFF: pick Merit or Community for a scholar
create or replace function public.assign_program(p_scholar uuid, p_program uuid)
returns void language plpgsql security definer
set search_path = public as $$
declare v_name text;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  select name into v_name from public.programs where id = p_program;
  if v_name is null then raise exception 'Program not found'; end if;
  update public.profiles set program_id = p_program
   where id = p_scholar and role = 'scholar';
  if not found then raise exception 'Scholar not found'; end if;
  perform public.log_action(null, p_scholar, 'assigned_program', 'Set to ' || v_name);
end $$;

-- SCHOLAR: submit grades (one per semester; resubmit only if rejected)
create or replace function public.submit_grades(
  p_term uuid, p_gwa numeric, p_units int, p_failed int,
  p_inc int, p_dropped int, p_proof text)
returns uuid language plpgsql security definer
set search_path = public as $$
declare
  me public.profiles%rowtype;
  ex public.submissions%rowtype;
  v_id uuid;
begin
  select * into me from public.profiles where id = auth.uid();
  if not found or me.role <> 'scholar' then raise exception 'Scholars only'; end if;
  if me.program_id is null then
    raise exception 'Staff has not assigned your scholarship yet'; end if;
  if coalesce(trim(p_proof), '') = '' then
    raise exception 'Attach your proof first'; end if;

  select * into ex from public.submissions
   where scholar_id = me.id and term_id = p_term;

  if found then
    if ex.verify_status = 'rejected' then
      update public.submissions
         set program_id = me.program_id, gwa = p_gwa, units = p_units,
             failed = p_failed, inc = p_inc, dropped = p_dropped,
             proof_path = p_proof, submitted_at = now(),
             verify_status = 'pending', verify_note = null,
             verified_by = null, verified_at = null,
             compliance = 'not_checked', reasons = null, is_late = null,
             decision = 'none', decision_note = null
       where id = ex.id;
      perform public.log_action(ex.id, me.id, 'resubmitted', 'Fixed and sent again');
      return ex.id;
    end if;
    raise exception 'REJECTED: you already submitted for this semester';
  end if;

  insert into public.submissions
    (scholar_id, term_id, program_id, gwa, units, failed, inc, dropped, proof_path)
  values (me.id, p_term, me.program_id, p_gwa, p_units, p_failed, p_inc, p_dropped, p_proof)
  returning id into v_id;
  perform public.log_action(v_id, me.id, 'submitted', 'Grades submitted');
  return v_id;
end $$;

-- STAFF: Verified or "Wrong, fix it"
create or replace function public.verify_submission(p_id uuid, p_ok boolean, p_note text)
returns void language plpgsql security definer
set search_path = public as $$
declare s public.submissions%rowtype;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  select * into s from public.submissions where id = p_id;
  if not found then raise exception 'Submission not found'; end if;
  if s.verify_status <> 'pending' then raise exception 'Already reviewed'; end if;
  if not p_ok and coalesce(trim(p_note), '') = '' then
    raise exception 'Write what is wrong so the scholar can fix it'; end if;

  update public.submissions
     set verify_status = case when p_ok then 'verified' else 'rejected' end,
         verify_note = nullif(trim(p_note), ''),
         verified_by = auth.uid(), verified_at = now()
   where id = p_id;
  perform public.log_action(p_id, s.scholar_id,
          case when p_ok then 'verified' else 'rejected' end, p_note);
end $$;

-- STAFF: run the rule check (only works if verified)
create or replace function public.check_rules(p_id uuid)
returns void language plpgsql security definer
set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  perform public.run_check(p_id);
end $$;

-- STAFF: Approved or Held (cannot approve if deficient)
create or replace function public.set_decision(p_id uuid, p_decision text, p_note text)
returns void language plpgsql security definer
set search_path = public as $$
declare s public.submissions%rowtype;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if p_decision not in ('approved','held') then raise exception 'Bad decision'; end if;
  select * into s from public.submissions where id = p_id;
  if not found then raise exception 'Submission not found'; end if;
  if s.compliance = 'not_checked' then
    raise exception 'Check the rules first'; end if;
  if p_decision = 'approved' and s.compliance <> 'compliant' then
    raise exception 'Cannot approve: scholar has deficiency'; end if;

  update public.submissions
     set decision = p_decision, decision_note = nullif(trim(p_note), '')
   where id = p_id;
  perform public.log_action(p_id, s.scholar_id, p_decision, p_note);
end $$;

-- ---------- FILE STORAGE (proof uploads) ----------
insert into storage.buckets (id, name, public)
values ('proofs', 'proofs', false)
on conflict (id) do nothing;

-- Scholar can upload only into folder named with own user id
create policy "proofs upload own" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'proofs' and (storage.foldername(name))[1] = auth.uid()::text);

-- Scholar reads own files. Staff reads all.
create policy "proofs read own or staff" on storage.objects
  for select to authenticated
  using (bucket_id = 'proofs'
         and ((storage.foldername(name))[1] = auth.uid()::text or public.is_staff()));

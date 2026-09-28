-- Execute once in a new Supabase project. Never put secret keys in the website.
create extension if not exists pgcrypto;
create table public.staff(user_id uuid primary key references auth.users(id) on delete cascade,role text not null default 'admin');
create table public.events(id uuid primary key default gen_random_uuid(),slug text unique not null check(slug ~ '^[a-z0-9-]+$'),title text not null,description text not null default '',venue text not null default '',start_at timestamptz,end_at timestamptz,cover_url text,status text not null default 'draft' check(status in ('draft','published','closed')),pass_percent int not null default 70 check(pass_percent between 0 and 100),retry_limit int not null default 2 check(retry_limit between 1 and 10),prefix text not null default 'S4',privacy_notice text not null default '',retention_note text not null default '',privacy_version int not null default 1,survey jsonb not null default '[]'::jsonb,quiz jsonb not null default '[]'::jsonb,created_at timestamptz not null default now());
create table public.templates(id uuid primary key default gen_random_uuid(),event_id uuid not null references public.events(id),version int not null,layout jsonb not null,created_at timestamptz not null default now(),unique(event_id,version));
create table public.visits(id uuid primary key default gen_random_uuid(),event_id uuid not null references public.events(id),full_name text not null,position text not null,affiliation text not null,province text not null,email text not null,phone text not null,publication_consent boolean not null default false,privacy_version int not null,consented_at timestamptz not null default now(),access_token uuid not null default gen_random_uuid(),created_at timestamptz not null default now(),unique(event_id,email));
create table public.survey_responses(visit_id uuid primary key references public.visits(id),answers jsonb not null,submitted_at timestamptz not null default now());
create table public.quiz_attempts(id uuid primary key default gen_random_uuid(),visit_id uuid not null references public.visits(id),answers jsonb not null,correct_by_question jsonb not null,correct_count int not null,score int not null,max_score int not null,passed boolean not null,created_at timestamptz not null default now());
create table public.counters(prefix text primary key,last_number bigint not null);
create table public.certificates(id uuid primary key default gen_random_uuid(),visit_id uuid unique not null references public.visits(id),event_id uuid not null references public.events(id),template_id uuid not null references public.templates(id),code text unique not null,verification_token uuid unique not null default gen_random_uuid(),passed_at timestamptz not null default now(),revoked_at timestamptz);
create index on public.visits(event_id);create index on public.visits(lower(email));create index on public.quiz_attempts(visit_id);create index on public.certificates(event_id);
create function public.is_staff() returns boolean language sql stable security definer set search_path=public as $$select exists(select 1 from staff where user_id=auth.uid())$$;
revoke all on function public.is_staff() from public;grant execute on function public.is_staff() to authenticated;
-- Owner-only table access. Anonymous access is limited to functions below.
alter table public.staff enable row level security;alter table public.events enable row level security;alter table public.templates enable row level security;alter table public.visits enable row level security;alter table public.survey_responses enable row level security;alter table public.quiz_attempts enable row level security;alter table public.counters enable row level security;alter table public.certificates enable row level security;
create policy staff_profile on public.staff for select to authenticated using(user_id=auth.uid());
create policy staff_events on public.events for all to authenticated using(public.is_staff()) with check(public.is_staff());
create policy staff_templates on public.templates for all to authenticated using(public.is_staff()) with check(public.is_staff());
create policy staff_visits on public.visits for select to authenticated using(public.is_staff());
create policy staff_surveys on public.survey_responses for select to authenticated using(public.is_staff());
create policy staff_attempts on public.quiz_attempts for select to authenticated using(public.is_staff());
create policy staff_certificates on public.certificates for select to authenticated using(public.is_staff());
revoke all on all tables in schema public from anon;
-- Only public graphics go in this bucket. Do not upload attendee details.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('expo-assets','expo-assets',true,5242880,array['image/png','image/jpeg','image/webp']) on conflict(id) do update set public=true;
create policy expo_asset_insert on storage.objects for insert to authenticated with check(bucket_id='expo-assets' and public.is_staff());
create policy expo_asset_update on storage.objects for update to authenticated using(bucket_id='expo-assets' and public.is_staff()) with check(bucket_id='expo-assets' and public.is_staff());
create policy expo_asset_delete on storage.objects for delete to authenticated using(bucket_id='expo-assets' and public.is_staff());

create function public.open_events() returns jsonb language sql security definer set search_path=public as $$select coalesce(jsonb_agg(jsonb_build_object('id',id,'slug',slug,'title',title,'description',description,'venue',venue,'start_at',start_at,'end_at',end_at,'cover_url',cover_url) order by start_at desc nulls last),'[]'::jsonb) from events where status='published'$$;
create function public.open_event(p_slug text) returns jsonb language plpgsql security definer set search_path=public as $$
declare e events; safe_quiz jsonb;
begin
 select * into e from events where slug=p_slug and status='published';if not found then return null;end if;
 select coalesce(jsonb_agg(q - 'answer' - 'alternatives'),'[]'::jsonb) into safe_quiz from jsonb_array_elements(e.quiz) q;
 return jsonb_build_object('id',e.id,'slug',e.slug,'title',e.title,'description',e.description,'venue',e.venue,'start_at',e.start_at,'end_at',e.end_at,'cover_url',e.cover_url,'pass_percent',e.pass_percent,'retry_limit',e.retry_limit,'privacy_notice',e.privacy_notice,'retention_note',e.retention_note,'privacy_version',e.privacy_version,'survey',e.survey,'quiz',safe_quiz);
end $$;
create function public.begin_visit(p_event uuid,p_name text,p_position text,p_affiliation text,p_province text,p_email text,p_phone text,p_publication boolean,p_privacy_version int) returns jsonb language plpgsql security definer set search_path=public as $$
declare e events;v visits;
begin
 select * into e from events where id=p_event and status='published';if not found or (e.start_at is not null and now()<e.start_at) or (e.end_at is not null and now()>e.end_at) then raise exception 'กิจกรรมยังไม่เปิดรับหรือปิดแล้ว';end if;
 if p_privacy_version<>e.privacy_version then raise exception 'กรุณาอ่านประกาศข้อมูลฉบับปัจจุบัน';end if;
 if trim(coalesce(p_name,''))='' or trim(coalesce(p_position,''))='' or trim(coalesce(p_affiliation,''))='' or trim(coalesce(p_province,''))='' or trim(coalesce(p_phone,''))='' or p_email !~* '^[^@ ]+@[^@ ]+\.[^@ ]+$' then raise exception 'กรอกข้อมูลให้ครบและตรวจสอบอีเมล';end if;
 insert into visits(event_id,full_name,position,affiliation,province,email,phone,publication_consent,privacy_version) values(e.id,left(trim(p_name),150),left(trim(p_position),150),left(trim(p_affiliation),150),left(trim(p_province),100),lower(left(trim(p_email),250)),left(trim(p_phone),30),coalesce(p_publication,false),p_privacy_version) on conflict(event_id,email) do nothing returning * into v;
 if not found then raise exception 'อีเมลนี้ลงทะเบียนแล้ว ใช้หน้าค้นหาเกียรติบัตรหรือสอบถามผู้ดูแล';end if;
 return jsonb_build_object('id',v.id,'token',v.access_token);
end $$;
create function public.send_survey(p_id uuid,p_token uuid,p_answers jsonb) returns boolean language plpgsql security definer set search_path=public as $$
declare e events;s jsonb;q jsonb;val text;
begin
 select evt.* into e from visits v join events evt on evt.id=v.event_id where v.id=p_id and v.access_token=p_token and evt.status='published';if not found then raise exception 'ไม่พบสิทธิ์เข้าร่วม';end if;
 if jsonb_typeof(p_answers)<>'object' then raise exception 'รูปแบบคำตอบไม่ถูกต้อง';end if;
 for s in select * from jsonb_array_elements(e.survey) loop
  for q in select * from jsonb_array_elements(coalesce(s->'questions','[]'::jsonb)) loop
   val:=trim(coalesce(p_answers->>(q->>'id'),''));
   if coalesce((q->>'required')::boolean,true) and val='' then raise exception 'กรุณาตอบแบบประเมินให้ครบ';end if;
   if val<>'' and q->>'kind'='rating' and val not in ('1','2','3','4','5') then raise exception 'ระดับคะแนนไม่ถูกต้อง';end if;
   if val<>'' and q->>'kind'='choice' and not coalesce((q->'options') ? val,false) then raise exception 'ตัวเลือกไม่ถูกต้อง';end if;
  end loop;
 end loop;
 insert into survey_responses(visit_id,answers) values(p_id,p_answers) on conflict(visit_id) do nothing;return true;
end $$;
create function public.send_quiz(p_id uuid,p_token uuid,p_answers jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare v visits;e events;q jsonb;ans text;correct_answer text;ok boolean;details jsonb:='{}'::jsonb;correct int:=0;score int:=0;maximum int:=0;points int;total int:=0;is_pass boolean;c certificates;t templates;next_no bigint;attempt_count int;
begin
 select * into v from visits where id=p_id and access_token=p_token for update;if not found then raise exception 'ไม่พบสิทธิ์เข้าร่วม';end if;
 select * into e from events where id=v.event_id and status='published';if not found then raise exception 'กิจกรรมปิดรับแล้ว';end if;
 if not exists(select 1 from survey_responses where visit_id=p_id) then raise exception 'กรุณาตอบแบบประเมินก่อน';end if;
 select * into c from certificates where visit_id=p_id;if found then return jsonb_build_object('passed',true,'code',c.code,'already',true);end if;
 select count(*) into attempt_count from quiz_attempts where visit_id=p_id;if attempt_count>=e.retry_limit then raise exception 'ครบจำนวนครั้งที่ทำได้';end if;
 if jsonb_typeof(p_answers)<>'object' then raise exception 'รูปแบบคำตอบไม่ถูกต้อง';end if;
 for q in select * from jsonb_array_elements(e.quiz) loop
  total:=total+1;points:=coalesce((q->>'points')::int,1);maximum:=maximum+points;ans:=trim(coalesce(p_answers->>(q->>'id'),''));correct_answer:=trim(coalesce(q->>'answer',''));ok:=false;
  if correct_answer='' then raise exception 'ข้อสอบยังตั้งค่าเฉลยไม่ครบ';end if;
  if q->>'kind'='short' then
   ok:=lower(regexp_replace(ans,'\s+',' ','g'))=lower(regexp_replace(correct_answer,'\s+',' ','g')) or exists(select 1 from jsonb_array_elements_text(coalesce(q->'alternatives','[]'::jsonb)) a(val) where lower(regexp_replace(trim(a.val),'\s+',' ','g'))=lower(regexp_replace(ans,'\s+',' ','g')));
  else ok:=ans=correct_answer and (q->>'kind'='truefalse' or coalesce((q->'options') ? ans,false));end if;
  if ok then correct:=correct+1;score:=score+points;end if;details:=details||jsonb_build_object(q->>'id',ok);
 end loop;
 if total=0 or maximum=0 then raise exception 'ยังไม่มีข้อสอบ';end if;
 is_pass:=score*100.0/maximum>=e.pass_percent;
 insert into quiz_attempts(visit_id,answers,correct_by_question,correct_count,score,max_score,passed) values(p_id,p_answers,details,correct,score,maximum,is_pass);
 if is_pass then
  select * into t from templates where event_id=e.id order by version desc limit 1;if not found then raise exception 'ยังไม่มีแบบเกียรติบัตร';end if;
  insert into counters(prefix,last_number) values(e.prefix,1) on conflict(prefix) do update set last_number=counters.last_number+1 returning last_number into next_no;
  insert into certificates(visit_id,event_id,template_id,code) values(v.id,e.id,t.id,e.prefix||'-'||lpad(next_no::text,6,'0')) returning * into c;
 end if;
 return jsonb_build_object('passed',is_pass,'score',score,'max_score',maximum,'correct_count',correct,'total',total,'remaining',e.retry_limit-attempt_count-1,'code',c.code);
end $$;
create function public.current_certificate(p_id uuid,p_token uuid) returns jsonb language sql security definer set search_path=public as $$select jsonb_build_object('code',c.code,'token',c.verification_token,'name',v.full_name,'event_title',e.title,'passed_at',c.passed_at,'layout',t.layout,'event_id',e.id) from certificates c join visits v on v.id=c.visit_id join events e on e.id=c.event_id join templates t on t.id=c.template_id where v.id=p_id and v.access_token=p_token and c.revoked_at is null limit 1$$;
create function public.my_certificates() returns jsonb language plpgsql security definer set search_path=public as $$declare result jsonb;begin if auth.uid() is null or nullif(auth.jwt()->>'email','') is null then raise exception 'ยืนยันอีเมลก่อน';end if;select coalesce(jsonb_agg(jsonb_build_object('code',c.code,'token',c.verification_token,'name',v.full_name,'event_title',e.title,'passed_at',c.passed_at,'layout',t.layout,'event_id',e.id) order by c.passed_at desc),'[]'::jsonb) into result from certificates c join visits v on v.id=c.visit_id join events e on e.id=c.event_id join templates t on t.id=c.template_id where lower(v.email)=lower(auth.jwt()->>'email') and c.revoked_at is null;return result;end $$;
create function public.verify_certificate(p_code text,p_token uuid) returns jsonb language sql security definer set search_path=public as $$select jsonb_build_object('code',c.code,'name',v.full_name,'event_title',e.title,'passed_at',c.passed_at,'valid',c.revoked_at is null) from certificates c join visits v on v.id=c.visit_id join events e on e.id=c.event_id where c.code=p_code and c.verification_token=p_token limit 1$$;
create function public.guard_template() returns trigger language plpgsql as $$begin if exists(select 1 from certificates where template_id=old.id) and old.layout is distinct from new.layout then raise exception 'แบบนี้ออกใบแล้ว ให้สร้างเวอร์ชันใหม่';end if;return new;end $$;
create trigger locked_template before update on public.templates for each row execute function public.guard_template();
create function public.asset_usage_bytes() returns bigint language plpgsql security definer set search_path=public,storage as $$begin if not public.is_staff() then raise exception 'ไม่มีสิทธิ์';end if;return coalesce((select sum(coalesce((metadata->>'size')::bigint,0)) from storage.objects where bucket_id='expo-assets'),0);end $$;
revoke all on function public.asset_usage_bytes() from public;grant execute on function public.asset_usage_bytes() to authenticated;

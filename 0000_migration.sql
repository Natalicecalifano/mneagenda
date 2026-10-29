create type public.app_role as enum ('admin');
create type public.booking_status as enum ('agendado','chegou','atendido','cancelado','nao_compareceu');

create table public.user_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  role app_role not null,
  unique (user_id, role)
);
grant select on public.user_roles to authenticated;
grant all on public.user_roles to service_role;
alter table public.user_roles enable row level security;
create policy "own roles" on public.user_roles for select to authenticated using (user_id = auth.uid());

create or replace function public.has_role(_user_id uuid, _role app_role)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = _user_id and role = _role)
$$;

-- First signed-in user becomes admin (bootstrap only)
create or replace function public.claim_first_admin()
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return false; end if;
  perform pg_advisory_xact_lock(424242);
  if not exists (select 1 from public.user_roles where role = 'admin') then
    insert into public.user_roles(user_id, role) values (auth.uid(), 'admin');
  end if;
  return public.has_role(auth.uid(), 'admin');
end $$;
revoke execute on function public.claim_first_admin() from anon, public;
grant execute on function public.claim_first_admin() to authenticated;

create table public.settings (
  id int primary key default 1 check (id = 1),
  daily_capacity int not null default 50 check (daily_capacity >= 0),
  slot_capacity int not null default 6 check (slot_capacity >= 0),
  group_size int not null default 6 check (group_size >= 1),
  open_weekdays int[] not null default '{1,2,3,4,5,6}',
  days_ahead int not null default 30 check (days_ahead between 1 and 365),
  payment_note text not null default 'O pagamento é realizado presencialmente no dia do atendimento, ao chegar ao local.',
  updated_at timestamptz not null default now()
);
insert into public.settings (id) values (1);
grant select on public.settings to anon, authenticated;
grant update on public.settings to authenticated;
grant all on public.settings to service_role;
alter table public.settings enable row level security;
create policy "public read settings" on public.settings for select to anon, authenticated using (true);
create policy "admin update settings" on public.settings for update to authenticated using (public.has_role(auth.uid(),'admin')) with check (public.has_role(auth.uid(),'admin'));

create table public.time_slots (
  id uuid primary key default gen_random_uuid(),
  start_time time not null unique,
  capacity int check (capacity >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
insert into public.time_slots(start_time) values ('08:00'),('09:00'),('10:00'),('11:00'),('13:00'),('14:00'),('15:00'),('16:00');
grant select on public.time_slots to anon, authenticated;
grant insert, update, delete on public.time_slots to authenticated;
grant all on public.time_slots to service_role;
alter table public.time_slots enable row level security;
create policy "public read slots" on public.time_slots for select to anon, authenticated using (true);
create policy "admin write slots" on public.time_slots for all to authenticated using (public.has_role(auth.uid(),'admin')) with check (public.has_role(auth.uid(),'admin'));

create table public.blocked_dates (
  day date primary key,
  reason text,
  created_at timestamptz not null default now()
);
grant select on public.blocked_dates to anon, authenticated;
grant insert, update, delete on public.blocked_dates to authenticated;
grant all on public.blocked_dates to service_role;
alter table public.blocked_dates enable row level security;
create policy "public read blocked" on public.blocked_dates for select to anon, authenticated using (true);
create policy "admin write blocked" on public.blocked_dates for all to authenticated using (public.has_role(auth.uid(),'admin')) with check (public.has_role(auth.uid(),'admin'));

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  full_name text not null check (char_length(full_name) between 2 and 120),
  whatsapp text not null check (char_length(whatsapp) between 8 and 20),
  email text check (email is null or char_length(email) <= 255),
  booking_date date not null,
  slot_time time not null,
  party_size int not null default 1 check (party_size >= 1),
  status booking_status not null default 'agendado',
  payment_status text not null default 'pendente',
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.bookings (booking_date, slot_time);
grant select, update, delete on public.bookings to authenticated;
grant all on public.bookings to service_role;
alter table public.bookings enable row level security;
create policy "admin read bookings" on public.bookings for select to authenticated using (public.has_role(auth.uid(),'admin'));
create policy "admin update bookings" on public.bookings for update to authenticated using (public.has_role(auth.uid(),'admin')) with check (public.has_role(auth.uid(),'admin'));
create policy "admin delete bookings" on public.bookings for delete to authenticated using (public.has_role(auth.uid(),'admin'));

create or replace function public.touch_updated_at() returns trigger language plpgsql set search_path = public as $$
begin new.updated_at = now(); return new; end $$;
create trigger bookings_touch before update on public.bookings for each row execute function public.touch_updated_at();

-- Public availability (counts only, no personal data)
create or replace function public.get_availability(_from date, _to date)
returns table(day date, booked int, capacity int, blocked boolean, open boolean)
language sql stable security definer set search_path = public as $$
  select d::date,
    coalesce((select sum(party_size) from bookings b where b.booking_date = d::date and b.status <> 'cancelado'),0)::int,
    s.daily_capacity,
    exists(select 1 from blocked_dates bd where bd.day = d::date),
    extract(isodow from d)::int % 7 = any(s.open_weekdays)
  from generate_series(_from, least(_to, _from + 370), interval '1 day') d, settings s
$$;

create or replace function public.get_day_slots(_date date)
returns table(slot_time time, capacity int, booked int)
language sql stable security definer set search_path = public as $$
  select t.start_time, coalesce(t.capacity, s.slot_capacity),
    coalesce((select sum(party_size) from bookings b where b.booking_date = _date and b.slot_time = t.start_time and b.status <> 'cancelado'),0)::int
  from time_slots t, settings s
  where t.active
  order by t.start_time
$$;

create or replace function public.create_booking(_name text, _whatsapp text, _email text, _date date, _time time)
returns table(code text, booking_date date, slot_time time, full_name text)
language plpgsql security definer set search_path = public as $$
declare
  s settings%rowtype;
  slot time_slots%rowtype;
  day_booked int; slot_booked int; slot_cap int;
  new_code text;
  today date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  _name := btrim(coalesce(_name,'')); _whatsapp := regexp_replace(coalesce(_whatsapp,''), '\D', '', 'g');
  _email := nullif(btrim(coalesce(_email,'')), '');
  if char_length(_name) < 2 or char_length(_name) > 120 then raise exception 'Nome inválido'; end if;
  if char_length(_whatsapp) < 10 or char_length(_whatsapp) > 13 then raise exception 'WhatsApp inválido'; end if;
  if _email is not null and (_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(_email) > 255) then raise exception 'E-mail inválido'; end if;

  perform pg_advisory_xact_lock(hashtext('booking:' || _date::text));
  select * into s from settings where id = 1;
  if _date < today or _date > today + s.days_ahead then raise exception 'Data indisponível'; end if;
  if not (extract(isodow from _date)::int % 7 = any(s.open_weekdays)) then raise exception 'Não há atendimento neste dia'; end if;
  if exists(select 1 from blocked_dates where day = _date) then raise exception 'Esta data está bloqueada'; end if;
  select * into slot from time_slots where start_time = _time and active;
  if not found then raise exception 'Horário indisponível'; end if;
  if _date = today and _time <= (now() at time zone 'America/Sao_Paulo')::time then raise exception 'Este horário já passou'; end if;

  select coalesce(sum(party_size),0) into day_booked from bookings where bookings.booking_date = _date and status <> 'cancelado';
  if day_booked + 1 > s.daily_capacity then raise exception 'Não há mais vagas para este dia'; end if;
  slot_cap := coalesce(slot.capacity, s.slot_capacity);
  select coalesce(sum(party_size),0) into slot_booked from bookings where bookings.booking_date = _date and bookings.slot_time = _time and status <> 'cancelado';
  if slot_booked + 1 > slot_cap then raise exception 'Não há mais vagas neste horário'; end if;

  loop
    new_code := upper(substr(translate(encode(gen_random_bytes(6),'base64'),'+/=0OIl1','XYZ'),1,6));
    exit when char_length(new_code) = 6 and not exists(select 1 from bookings where bookings.code = new_code);
  end loop;

  insert into bookings(code, full_name, whatsapp, email, booking_date, slot_time)
  values (new_code, _name, _whatsapp, _email, _date, _time);
  return query select new_code, _date, _time, _name;
end $$;

grant execute on function public.get_availability(date,date) to anon, authenticated;
grant execute on function public.get_day_slots(date) to anon, authenticated;
grant execute on function public.create_booking(text,text,text,date,time) to anon, authenticated;
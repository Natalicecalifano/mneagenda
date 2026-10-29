ALTER TYPE public.booking_status ADD VALUE IF NOT EXISTS 'concluiu';
ALTER TYPE public.booking_status ADD VALUE IF NOT EXISTS 'faltou';
ALTER TYPE public.booking_status ADD VALUE IF NOT EXISTS 'reagendou';
ALTER TYPE public.booking_status ADD VALUE IF NOT EXISTS 'repetir';
ALTER TYPE public.booking_status ADD VALUE IF NOT EXISTS 'passou';

CREATE TABLE public.customers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name text NOT NULL,
  whatsapp text NOT NULL UNIQUE,
  email text,
  cycle text CHECK (cycle IN ('i1','i2','i3','P1','P2','Aresta')),
  confirmed boolean NOT NULL DEFAULT false,
  last_activity_date date,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.customers TO authenticated;
GRANT ALL ON public.customers TO service_role;
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admin all customers" ON public.customers FOR ALL TO authenticated
  USING (public.has_role(auth.uid(),'admin')) WITH CHECK (public.has_role(auth.uid(),'admin'));

CREATE TABLE public.schedule_days (
  day date PRIMARY KEY,
  period text NOT NULL DEFAULT 'integral' CHECK (period IN ('integral','manha','tarde')),
  start_time time NOT NULL DEFAULT '08:00',
  end_time time NOT NULL DEFAULT '18:00',
  iniciar_capacity int NOT NULL DEFAULT 0 CHECK (iniciar_capacity >= 0),
  p1_capacity int NOT NULL DEFAULT 0 CHECK (p1_capacity >= 0),
  p2_capacity int NOT NULL DEFAULT 0 CHECK (p2_capacity >= 0),
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.schedule_days TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.schedule_days TO authenticated;
GRANT ALL ON public.schedule_days TO service_role;
ALTER TABLE public.schedule_days ENABLE ROW LEVEL SECURITY;
CREATE POLICY "public read schedule" ON public.schedule_days FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "admin write schedule" ON public.schedule_days FOR ALL TO authenticated
  USING (public.has_role(auth.uid(),'admin')) WITH CHECK (public.has_role(auth.uid(),'admin'));

ALTER TABLE public.bookings
  ADD COLUMN category text,
  ADD COLUMN cycle text,
  ADD COLUMN format text,
  ADD COLUMN customer_id uuid,
  ADD COLUMN group_id uuid;

CREATE OR REPLACE FUNCTION public.get_schedule(_from date, _to date)
RETURNS TABLE(day date, period text, start_time time, end_time time, iniciar_left int, p1_left int, p2_left int)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  select s.day, s.period, s.start_time, s.end_time,
    s.iniciar_capacity - (select count(distinct coalesce(b.group_id,b.id)) from bookings b where b.booking_date=s.day and b.category='Iniciar' and b.status::text not in ('cancelado','reagendou'))::int,
    s.p1_capacity - (select count(*) from bookings b where b.booking_date=s.day and b.category='P1' and b.status::text not in ('cancelado','reagendou'))::int,
    s.p2_capacity - (select count(*) from bookings b where b.booking_date=s.day and b.category='P2' and b.status::text not in ('cancelado','reagendou'))::int
  from schedule_days s where s.day between _from and least(_to, _from + 370) order by s.day
$$;

CREATE OR REPLACE FUNCTION public.lookup_profile(_whatsapp text)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  select coalesce((select case when c.cycle in ('P1','P2','Aresta') then c.cycle else 'iniciante' end
    from customers c where c.whatsapp = regexp_replace(coalesce(_whatsapp,''),'\D','','g')), 'iniciante')
$$;

CREATE OR REPLACE FUNCTION public.book_cycles(_name text, _whatsapp text, _email text, _category text, _format text, _dates date[])
RETURNS TABLE(code text, booking_date date, cycle text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
declare
  today date := (now() at time zone 'America/Sao_Paulo')::date;
  prof text; cust uuid; grp uuid := gen_random_uuid();
  ds date[]; d date; sd schedule_days%rowtype; used int; cap int; new_code text;
  plan_dates date[]; plan_cycles text[]; i int;
begin
  _name := btrim(coalesce(_name,'')); _whatsapp := regexp_replace(coalesce(_whatsapp,''),'\D','','g');
  _email := nullif(btrim(coalesce(_email,'')),'');
  if char_length(_name) < 2 or char_length(_name) > 120 then raise exception 'Nome inválido'; end if;
  if char_length(_whatsapp) < 10 or char_length(_whatsapp) > 13 then raise exception 'WhatsApp inválido'; end if;
  if _email is not null and (_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(_email) > 255) then raise exception 'E-mail inválido'; end if;
  select array_agg(x order by x) into ds from (select distinct unnest(_dates) x) t;
  if ds is null then raise exception 'Selecione as datas'; end if;

  prof := public.lookup_profile(_whatsapp);
  if prof = 'iniciante' then
    if _category <> 'Iniciar' then raise exception 'Iniciantes devem agendar a categoria Iniciar'; end if;
  elsif prof = 'Aresta' then
    if _category not in ('P1','P2') then raise exception 'Categoria inválida'; end if;
  elsif _category <> prof then raise exception 'Seu ciclo atual é %', prof; end if;

  if _category = 'Iniciar' then
    if _format = 'dia_inteiro' then
      if array_length(ds,1) <> 1 then raise exception 'Dia inteiro exige 1 data'; end if;
      plan_dates := array[ds[1],ds[1],ds[1]];
    elsif _format = 'duas_tardes' then
      if array_length(ds,1) <> 2 then raise exception 'Duas tardes exige 2 datas'; end if;
      plan_dates := array[ds[1],ds[1],ds[2]];
    else raise exception 'Formato inválido'; end if;
    plan_cycles := array['i1','i2','i3'];
  else
    if array_length(ds,1) <> 1 then raise exception 'Selecione 1 data'; end if;
    _format := null; plan_dates := array[ds[1]]; plan_cycles := array[_category];
  end if;

  foreach d in array ds loop
    perform pg_advisory_xact_lock(hashtext('booking:' || d::text));
    select * into sd from schedule_days s where s.day = d;
    if not found or d < today then raise exception 'Data % indisponível', to_char(d,'DD/MM'); end if;
    if _format = 'dia_inteiro' and sd.period <> 'integral' then raise exception 'Data % não é de período integral', to_char(d,'DD/MM'); end if;
    if _format = 'duas_tardes' and sd.period = 'manha' then raise exception 'Data % não tem turno da tarde', to_char(d,'DD/MM'); end if;
    if _category = 'Iniciar' then
      cap := sd.iniciar_capacity;
      select count(distinct coalesce(b.group_id,b.id)) into used from bookings b where b.booking_date=d and b.category='Iniciar' and b.status::text not in ('cancelado','reagendou');
    else
      cap := case _category when 'P1' then sd.p1_capacity else sd.p2_capacity end;
      select count(*) into used from bookings b where b.booking_date=d and b.category=_category and b.status::text not in ('cancelado','reagendou');
    end if;
    if used + 1 > cap then raise exception 'Sem vagas de % em %', _category, to_char(d,'DD/MM'); end if;
  end loop;

  insert into customers(full_name, whatsapp, email) values (_name, _whatsapp, _email)
  on conflict (whatsapp) do update set full_name = excluded.full_name, email = coalesce(excluded.email, customers.email)
  returning id into cust;

  for i in 1..array_length(plan_dates,1) loop
    select * into sd from schedule_days s where s.day = plan_dates[i];
    loop new_code := public.gen_booking_code(); exit when not exists(select 1 from bookings b where b.code=new_code); end loop;
    insert into bookings(code, full_name, whatsapp, email, booking_date, slot_time, visit_type, category, cycle, format, customer_id, group_id)
    values (new_code, _name, _whatsapp, _email, plan_dates[i], sd.start_time, _category, _category, plan_cycles[i], _format, cust, grp);
    code := new_code; booking_date := plan_dates[i]; cycle := plan_cycles[i]; return next;
  end loop;
end $$;

CREATE OR REPLACE FUNCTION public.customer_action(_code text, _whatsapp text, _action text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
declare n int;
begin
  if _action not in ('chegou','cancelado','reagendou') then raise exception 'Ação permitida apenas ao administrador'; end if;
  update bookings set status = _action::booking_status
   where code = upper(btrim(_code)) and whatsapp = regexp_replace(coalesce(_whatsapp,''),'\D','','g')
     and status::text in ('agendado','chegou');
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Reserva não encontrada ou já finalizada'; end if;
  return _action;
end $$;

CREATE OR REPLACE FUNCTION public.on_booking_status()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
begin
  if new.customer_id is not null and new.status is distinct from old.status then
    update customers set last_activity_date = greatest(coalesce(last_activity_date, new.booking_date), new.booking_date) where id = new.customer_id;
    if new.status::text = 'passou' then
      update customers set cycle = case coalesce(cycle, new.cycle)
        when 'i1' then 'i2' when 'i2' then 'i3' when 'i3' then 'P1' when 'P1' then 'P2' when 'P2' then 'Aresta' else 'Aresta' end
      where id = new.customer_id;
    end if;
  end if;
  return new;
end $$;
CREATE TRIGGER bookings_status_customer AFTER UPDATE OF status ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION public.on_booking_status();

GRANT EXECUTE ON FUNCTION public.get_schedule(date,date), public.lookup_profile(text),
  public.book_cycles(text,text,text,text,text,date[]), public.customer_action(text,text,text) TO anon, authenticated;
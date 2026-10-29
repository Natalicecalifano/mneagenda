CREATE OR REPLACE FUNCTION public.get_schedule(_from date, _to date)
 RETURNS TABLE(day date, period text, start_time time without time zone, end_time time without time zone, iniciar_left integer, p1_left integer, p2_left integer)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  select s.day, s.period, s.start_time, s.end_time,
    s.iniciar_capacity - coalesce((select sum(g.ps) from (select distinct coalesce(b.group_id,b.id) gid, b.party_size ps from bookings b where b.booking_date=s.day and b.category='Iniciar' and b.status::text not in ('cancelado','reagendou')) g),0)::int,
    s.p1_capacity - coalesce((select sum(b.party_size) from bookings b where b.booking_date=s.day and b.category='P1' and b.status::text not in ('cancelado','reagendou')),0)::int,
    s.p2_capacity - coalesce((select sum(b.party_size) from bookings b where b.booking_date=s.day and b.category='P2' and b.status::text not in ('cancelado','reagendou')),0)::int
  from schedule_days s where s.day between _from and least(_to, _from + 370) order by s.day
$$;

CREATE OR REPLACE FUNCTION public.book_cycles(_name text, _whatsapp text, _email text, _category text, _format text, _dates date[], _party integer)
 RETURNS TABLE(code text, booking_date date, cycle text)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  today date := (now() at time zone 'America/Sao_Paulo')::date;
  prof text; cust uuid; grp uuid := gen_random_uuid();
  ds date[]; d date; sd schedule_days%rowtype; used int; cap int; new_code text;
  plan_dates date[]; plan_cycles text[]; i int; p1 text; p2 text;
begin
  _name := btrim(coalesce(_name,'')); _whatsapp := regexp_replace(coalesce(_whatsapp,''),'\D','','g');
  _email := nullif(btrim(coalesce(_email,'')),'');
  _party := coalesce(_party,1);
  if _party < 1 or _party > 10 then raise exception 'Quantidade de pessoas inválida (1 a 10)'; end if;
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
    elsif _format in ('duas_tardes','manha_tarde') then
      if array_length(ds,1) <> 2 then raise exception 'Este formato exige 2 datas'; end if;
      plan_dates := array[ds[1],ds[1],ds[2]];
      if _format = 'manha_tarde' then
        select s.period into p1 from schedule_days s where s.day = ds[1];
        select s.period into p2 from schedule_days s where s.day = ds[2];
        if not ((p1 in ('manha','integral') and p2 in ('tarde','integral')) or (p1 in ('tarde','integral') and p2 in ('manha','integral'))) then
          raise exception 'Escolha uma data com manhã e outra com tarde';
        end if;
      end if;
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
      select coalesce(sum(g.ps),0) into used from (select distinct coalesce(b.group_id,b.id) gid, b.party_size ps from bookings b where b.booking_date=d and b.category='Iniciar' and b.status::text not in ('cancelado','reagendou')) g;
    else
      cap := case _category when 'P1' then sd.p1_capacity else sd.p2_capacity end;
      select coalesce(sum(b.party_size),0) into used from bookings b where b.booking_date=d and b.category=_category and b.status::text not in ('cancelado','reagendou');
    end if;
    if used + _party > cap then raise exception 'Sem vagas suficientes de % em % (restam %)', _category, to_char(d,'DD/MM'), greatest(cap-used,0); end if;
  end loop;

  insert into customers(full_name, whatsapp, email) values (_name, _whatsapp, _email)
  on conflict (whatsapp) do update set full_name = excluded.full_name, email = coalesce(excluded.email, customers.email)
  returning id into cust;

  for i in 1..array_length(plan_dates,1) loop
    select * into sd from schedule_days s where s.day = plan_dates[i];
    loop new_code := public.gen_booking_code(); exit when not exists(select 1 from bookings b where b.code=new_code); end loop;
    insert into bookings(code, full_name, whatsapp, email, booking_date, slot_time, visit_type, category, cycle, format, customer_id, group_id, party_size)
    values (new_code, _name, _whatsapp, _email, plan_dates[i], sd.start_time, _category, _category, plan_cycles[i], _format, cust, grp, _party);
    code := new_code; booking_date := plan_dates[i]; cycle := plan_cycles[i]; return next;
  end loop;
end $function$;

GRANT EXECUTE ON FUNCTION public.book_cycles(text,text,text,text,text,date[],integer) TO anon, authenticated, service_role;
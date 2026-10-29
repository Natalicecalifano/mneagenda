ALTER TABLE public.bookings
ADD COLUMN visit_type text NOT NULL DEFAULT 'Ciclo Interno';

ALTER TABLE public.bookings
ADD CONSTRAINT bookings_visit_type_allowed
CHECK (visit_type IN ('Ciclo Interno', 'Arestas', 'Janela das Possibilidades'));

CREATE OR REPLACE FUNCTION public.create_booking(
  _name text,
  _whatsapp text,
  _email text,
  _date date,
  _time time without time zone,
  _visit_type text
)
RETURNS TABLE(code text, booking_date date, slot_time time without time zone, full_name text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  s settings%rowtype;
  slot time_slots%rowtype;
  day_booked int; slot_booked int; slot_cap int;
  new_code text;
  today date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  _name := btrim(coalesce(_name,''));
  _whatsapp := regexp_replace(coalesce(_whatsapp,''), '\D', '', 'g');
  _email := nullif(btrim(coalesce(_email,'')), '');
  _visit_type := btrim(coalesce(_visit_type,''));

  if char_length(_name) < 2 or char_length(_name) > 120 then raise exception 'Nome inválido'; end if;
  if char_length(_whatsapp) < 10 or char_length(_whatsapp) > 13 then raise exception 'WhatsApp inválido'; end if;
  if _email is not null and (_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(_email) > 255) then raise exception 'E-mail inválido'; end if;
  if _visit_type not in ('Ciclo Interno', 'Arestas', 'Janela das Possibilidades') then raise exception 'Tipo de visita inválido'; end if;

  perform pg_advisory_xact_lock(hashtext('booking:' || _date::text));
  select * into s from settings where id = 1;
  if _date < today or _date > today + s.days_ahead then raise exception 'Data indisponível'; end if;
  if not (extract(isodow from _date)::int % 7 = any(s.open_weekdays)) then raise exception 'Não há atendimento neste dia'; end if;
  if exists(select 1 from blocked_dates where day = _date) then raise exception 'Esta data está bloqueada'; end if;
  select * into slot from time_slots where start_time = _time and active;
  if not found then raise exception 'Horário indisponível'; end if;
  if _date = today and _time <= (now() at time zone 'America/Sao_Paulo')::time then raise exception 'Este horário já passou'; end if;

  select coalesce(sum(b.party_size),0) into day_booked from bookings b where b.booking_date = _date and b.status <> 'cancelado';
  if day_booked + 1 > s.daily_capacity then raise exception 'Não há mais vagas para este dia'; end if;
  slot_cap := coalesce(slot.capacity, s.slot_capacity);
  select coalesce(sum(b.party_size),0) into slot_booked from bookings b where b.booking_date = _date and b.slot_time = _time and b.status <> 'cancelado';
  if slot_booked + 1 > slot_cap then raise exception 'Não há mais vagas neste horário'; end if;

  loop
    new_code := public.gen_booking_code();
    exit when not exists(select 1 from bookings b where b.code = new_code);
  end loop;

  insert into bookings(code, full_name, whatsapp, email, booking_date, slot_time, visit_type)
  values (new_code, _name, _whatsapp, _email, _date, _time, _visit_type);
  return query select new_code, _date, _time, _name;
end
$function$;

GRANT EXECUTE ON FUNCTION public.create_booking(text, text, text, date, time without time zone, text) TO anon, authenticated, service_role;
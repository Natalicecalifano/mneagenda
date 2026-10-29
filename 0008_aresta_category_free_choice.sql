ALTER TABLE public.schedule_days ADD COLUMN IF NOT EXISTS aresta_capacity integer NOT NULL DEFAULT 0;
ALTER TABLE public.bookings DROP CONSTRAINT IF EXISTS bookings_visit_type_allowed;
ALTER TABLE public.bookings ADD CONSTRAINT bookings_visit_type_allowed CHECK (visit_type IN ('Ciclo Interno','Arestas','Janela das Possibilidades','Iniciar','P1','P2','Aresta'));

DROP FUNCTION IF EXISTS public.get_schedule(date, date);
CREATE FUNCTION public.get_schedule(_from date, _to date)
 RETURNS TABLE(day date, period text, start_time time without time zone, end_time time without time zone, iniciar_left integer, p1_left integer, p2_left integer, aresta_left integer)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  select s.day, s.period, s.start_time, s.end_time,
    s.iniciar_capacity - coalesce((select sum(g.ps) from (select distinct coalesce(b.group_id,b.id) gid, b.party_size ps from bookings b where b.booking_date=s.day and b.category='Iniciar' and b.status::text not in ('cancelado','reagendou')) g),0)::int,
    s.p1_capacity - coalesce((select sum(b.party_size) from bookings b where b.booking_date=s.day and b.category='P1' and b.status::text not in ('cancelado','reagendou')),0)::int,
    s.p2_capacity - coalesce((select sum(b.party_size) from bookings b where b.booking_date=s.day and b.category='P2' and b.status::text not in ('cancelado','reagendou')),0)::int,
    s.aresta_capacity - coalesce((select sum(b.party_size) from bookings b where b.booking_date=s.day and b.category='Aresta' and b.status::text not in ('cancelado','reagendou')),0)::int
  from schedule_days s where s.day between _from and least(_to, _from + 370) order by s.day
$$;
GRANT EXECUTE ON FUNCTION public.get_schedule(date,date) TO anon, authenticated, service_role;

DO $$ DECLARE src text; a int; b int; BEGIN
  SELECT pg_get_functiondef('public.book_cycles(text,text,text,text,text,date[],integer)'::regprocedure) INTO src;
  a := position('prof := public.lookup_profile' in src);
  b := position('if _category = ''Iniciar'' then' in src);
  IF a = 0 OR b = 0 OR b < a THEN RAISE EXCEPTION 'markers not found'; END IF;
  src := substr(src, 1, a-1) || 'if _category not in (''Iniciar'',''P1'',''P2'',''Aresta'') then raise exception ''Categoria inválida''; end if;
  ' || substr(src, b);
  src := replace(src, 'case _category when ''P1'' then sd.p1_capacity else sd.p2_capacity end', 'case _category when ''P1'' then sd.p1_capacity when ''P2'' then sd.p2_capacity else sd.aresta_capacity end');
  EXECUTE src;
END $$;
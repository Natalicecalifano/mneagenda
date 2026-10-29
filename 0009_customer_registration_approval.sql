ALTER TABLE public.customers ADD COLUMN IF NOT EXISTS dependents text[] NOT NULL DEFAULT '{}';

CREATE OR REPLACE FUNCTION public.register_customer(_name text, _whatsapp text, _email text, _dependents text[])
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
declare c customers%rowtype; deps text[];
begin
  _name := btrim(coalesce(_name,'')); _whatsapp := regexp_replace(coalesce(_whatsapp,''),'\D','','g');
  _email := nullif(btrim(coalesce(_email,'')),'');
  if char_length(_name) < 3 or char_length(_name) > 120 then raise exception 'Nome inválido'; end if;
  if char_length(_whatsapp) < 10 or char_length(_whatsapp) > 11 then raise exception 'Celular inválido'; end if;
  if _email is not null and (_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(_email) > 255) then raise exception 'E-mail inválido'; end if;
  select coalesce(array_agg(btrim(x)), '{}') into deps from unnest(coalesce(_dependents,'{}')) x where btrim(x) <> '';
  if cardinality(deps) > 9 then raise exception 'Máximo de 9 dependentes'; end if;
  if exists (select 1 from unnest(deps) x where char_length(x) < 2 or char_length(x) > 120) then raise exception 'Nome de dependente inválido'; end if;
  select * into c from customers where whatsapp = _whatsapp;
  if found then
    return case when c.confirmed then 'aprovado' else 'pendente' end;
  end if;
  insert into customers(full_name, whatsapp, email, dependents, confirmed) values (_name, _whatsapp, _email, deps, false);
  return 'novo';
end $$;
REVOKE ALL ON FUNCTION public.register_customer(text,text,text,text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_customer(text,text,text,text[]) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.customer_status(_whatsapp text)
RETURNS TABLE(status text, allowed text, party integer) LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  select case when c.id is null then 'nao_cadastrado' when c.confirmed then 'aprovado' else 'pendente' end,
    case when c.confirmed then case when c.cycle in ('P1','P2','Aresta') then c.cycle else 'Iniciar' end end,
    case when c.confirmed then 1 + cardinality(c.dependents) end
  from (select 1) one left join customers c on c.whatsapp = regexp_replace(coalesce(_whatsapp,''),'\D','','g')
$$;
REVOKE ALL ON FUNCTION public.customer_status(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_status(text) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.book_approved(_whatsapp text, _category text, _format text, _dates date[])
RETURNS TABLE(code text, booking_date date, cycle text) LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
declare c customers%rowtype; allowed text;
begin
  select * into c from customers where whatsapp = regexp_replace(coalesce(_whatsapp,''),'\D','','g');
  if not found then raise exception 'Faça seu cadastro primeiro'; end if;
  if not c.confirmed then raise exception 'Seu cadastro ainda está em análise pela equipe'; end if;
  allowed := case when c.cycle in ('P1','P2','Aresta') then c.cycle else 'Iniciar' end;
  if _category <> allowed then raise exception 'Seu ciclo liberado é %', allowed; end if;
  return query select * from public.book_cycles(c.full_name, c.whatsapp, coalesce(c.email,''), _category, _format, _dates, 1 + cardinality(c.dependents));
end $$;
REVOKE ALL ON FUNCTION public.book_approved(text,text,text,date[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.book_approved(text,text,text,date[]) TO anon, authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.book_cycles(text,text,text,text,text,date[],integer) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.book_cycles(text,text,text,text,text,date[]) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.create_booking(text,text,text,date,time) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.create_booking(text,text,text,date,time,text) FROM PUBLIC, anon, authenticated;
DO $$ DECLARE src text; BEGIN
  SELECT pg_get_functiondef('public.book_cycles(text,text,text,text,text,date[],integer)'::regprocedure) INTO src;
  src := replace(src, '''duas_tardes'',''manha_tarde''', '''duas_tardes'',''manha_tarde'',''tarde_integral''');
  src := replace(src, 'if _format = ''manha_tarde'' then', 'if _format = ''tarde_integral'' then
        select s.period into p1 from schedule_days s where s.day = ds[1];
        select s.period into p2 from schedule_days s where s.day = ds[2];
        if not ((p1 = ''tarde'' and p2 = ''integral'') or (p1 = ''integral'' and p2 = ''tarde'')) then
          raise exception ''Escolha uma data à tarde e outra de período integral'';
        end if;
      end if;
      if _format = ''manha_tarde'' then');
  src := replace(src, 'if _format = ''duas_tardes'' and sd.period = ''manha''', 'if _format in (''duas_tardes'',''tarde_integral'') and sd.period = ''manha''');
  EXECUTE src;
END $$;
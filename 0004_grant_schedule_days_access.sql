GRANT SELECT ON public.schedule_days TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.schedule_days TO authenticated;
GRANT ALL ON public.schedule_days TO service_role;
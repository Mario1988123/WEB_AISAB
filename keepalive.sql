-- ============================================================
-- AISAB — mantener el proyecto de Supabase DESPIERTO
-- Pegar en Supabase (SQL Editor → Run). Se ejecuta UNA sola vez.
--
-- Crea una función mínima `ping()` que el cron de GitHub Actions
-- llamará cada pocos días. Cada llamada es una consulta real a
-- Postgres, así que Supabase cuenta el proyecto como activo y no
-- lo pausa por inactividad.
--
-- No toca ni lee la tabla `sugerencias`: solo devuelve la hora.
-- ============================================================

create or replace function public.ping()
returns text
language sql
security definer
set search_path = public
as $$
  select 'ok ' || now()::text;
$$;

revoke all on function public.ping() from public;
grant execute on function public.ping() to anon;

-- ============================================================
-- AISAB — script para pegar en Supabase (SQL Editor → Run)
-- Crea la tabla de sugerencias y la seguridad:
--   · cualquiera puede ENVIAR (insertar)
--   · LEER solo con la clave, validada EN EL SERVIDOR
-- ============================================================

create extension if not exists pgcrypto;

create table if not exists public.sugerencias (
  id bigint generated always as identity primary key,
  creada timestamptz not null default now(),
  tipo text not null check (tipo in ('Queja','Sugerencia','Pregunta','Felicitación')),
  area text not null,
  zona text not null,
  calle text,
  texto text not null,
  anonima boolean not null default true,
  nombre text,
  contacto text,
  estado text not null default 'Nueva' check (estado in ('Nueva','Vista','Resuelta'))
);

alter table public.sugerencias enable row level security;

drop policy if exists "insercion publica" on public.sugerencias;
create policy "insercion publica" on public.sugerencias
  for insert to anon with check (true);
-- (sin política de SELECT: nadie puede leer directamente)

-- Clave del panel: AISAB2010 (guardada como hash SHA-256)
create or replace function public.admin_listar(clave text)
returns setof public.sugerencias
language plpgsql security definer set search_path = public as $$
begin
  if encode(digest(clave,'sha256'),'hex')
     <> 'c8f70915b4cb236f9fc9b97a33151a34a26b40e45ad7f8474de59f01b624ebd5' then
    raise exception 'clave incorrecta';
  end if;
  return query select * from public.sugerencias order by creada desc;
end $$;

create or replace function public.admin_estado(clave text, sid bigint, nuevo text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if encode(digest(clave,'sha256'),'hex')
     <> 'c8f70915b4cb236f9fc9b97a33151a34a26b40e45ad7f8474de59f01b624ebd5' then
    raise exception 'clave incorrecta';
  end if;
  update public.sugerencias set estado = nuevo where id = sid;
end $$;

grant execute on function public.admin_listar(text) to anon;
grant execute on function public.admin_estado(text, bigint, text) to anon;

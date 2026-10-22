-- ============================================================
-- AISAB — registro de simpatizantes y afiliados (www.aisab.es/afiliados)
-- Pegar en Supabase (SQL Editor → Run). Se puede ejecutar más de una vez.
--   · cualquiera puede ENVIAR su solicitud (insertar)
--   · nadie puede LEER directamente: solo el panel, con la clave,
--     validada EN EL SERVIDOR (misma clave que el panel de sugerencias)
-- Ojo: ser simpatizante o afiliado revela opinión política (dato
-- de categoría especial, art. 9 RGPD). Por eso no hay índice único
-- por correo: un error de duplicado delataría quién está registrado.
-- ============================================================

create extension if not exists pgcrypto;

create table if not exists public.afiliaciones (
  id bigint generated always as identity primary key,
  creada timestamptz not null default now(),
  tipo text not null check (tipo in ('Simpatizante','Afiliado')),
  nombre text not null check (char_length(nombre) between 1 and 80),
  apellidos text not null check (char_length(apellidos) between 1 and 120),
  correo text not null check (char_length(correo) between 5 and 160 and correo like '%_@_%'),
  telefono text not null check (char_length(telefono) between 9 and 20),
  acepta_privacidad boolean not null check (acepta_privacidad),
  consentimiento boolean not null check (consentimiento),
  estado text not null default 'Pendiente'
    check (estado in ('Pendiente','Contactada','Alta','Descartada'))
);

alter table public.afiliaciones enable row level security;

drop policy if exists "insercion publica" on public.afiliaciones;
create policy "insercion publica" on public.afiliaciones
  for insert to anon
  with check (estado = 'Pendiente');
-- (sin política de SELECT, UPDATE ni DELETE: nadie puede leer ni tocar directamente)

-- anon solo puede rellenar estas columnas (ni la fecha ni el estado)
revoke all on public.afiliaciones from anon, authenticated;
grant insert (tipo, nombre, apellidos, correo, telefono, acepta_privacidad, consentimiento)
  on public.afiliaciones to anon;

create or replace function public.admin_afiliaciones(clave text)
returns setof public.afiliaciones
language plpgsql security definer set search_path = public, extensions as $$
begin
  if encode(extensions.digest(clave,'sha256'),'hex')
     <> 'c8f70915b4cb236f9fc9b97a33151a34a26b40e45ad7f8474de59f01b624ebd5' then
    raise exception 'clave incorrecta';
  end if;
  return query select * from public.afiliaciones order by creada desc;
end $$;

create or replace function public.admin_afiliacion_estado(clave text, aid bigint, nuevo text)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if encode(extensions.digest(clave,'sha256'),'hex')
     <> 'c8f70915b4cb236f9fc9b97a33151a34a26b40e45ad7f8474de59f01b624ebd5' then
    raise exception 'clave incorrecta';
  end if;
  update public.afiliaciones set estado = nuevo where id = aid;
end $$;

revoke execute on function public.admin_afiliaciones(text) from public;
revoke execute on function public.admin_afiliacion_estado(text, bigint, text) from public;
grant execute on function public.admin_afiliaciones(text) to anon;
grant execute on function public.admin_afiliacion_estado(text, bigint, text) to anon;

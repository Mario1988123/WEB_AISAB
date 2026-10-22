-- ============================================================
-- AISAB — base de datos de www.aisab.es (sustituye a supabase.sql y afiliados.sql)
-- Pegar en Supabase (SQL Editor → Run). Se puede ejecutar más de una vez.
--
-- El proyecto Supabase lo comparte ARCACTA (sus tablas viven en `public`).
-- Todo lo de AISAB vive en el esquema `aisab`, que NO está expuesto en la API:
-- desde la web solo se llega a través de las funciones `public.*` de abajo.
--
--   · sugerencias  — formulario de quejas y sugerencias
--   · socios       — simpatizantes y afiliados con cuenta (correo + contraseña)
--   · sesiones     — sesiones abiertas de los socios (se guarda el hash del token)
--   · comunicados  — avisos de la zona de socios
--   · documentos   — PDFs de la zona de socios (dentro de la base de datos)
--
-- Ser simpatizante o afiliado revela opinión política (art. 9 RGPD):
-- el registro no dice si un correo ya existe y nadie lee las tablas directamente.
-- La clave del panel /admin se valida en el servidor (hash SHA-256).
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

create schema if not exists aisab;
revoke all on schema aisab from public, anon, authenticated;

-- ---------- sugerencias (se mueve desde public) ----------
do $$
begin
  if to_regclass('public.sugerencias') is not null
     and (select relkind from pg_class where oid = 'public.sugerencias'::regclass) = 'r' then
    alter table public.sugerencias set schema aisab;
  end if;
end $$;

create table if not exists aisab.sugerencias (
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
alter table aisab.sugerencias enable row level security;
drop policy if exists "insercion publica" on aisab.sugerencias;

-- ---------- socios ----------
create table if not exists aisab.socios (
  id bigint generated always as identity primary key,
  creada timestamptz not null default now(),
  tipo text not null check (tipo in ('Simpatizante','Afiliado')),
  nombre text not null check (char_length(nombre) between 1 and 80),
  apellidos text not null check (char_length(apellidos) between 1 and 120),
  correo text not null check (char_length(correo) between 5 and 160 and correo like '%_@_%'),
  telefono text not null check (char_length(telefono) between 9 and 20),
  clave_hash text not null,
  idioma text not null default 'es' check (idioma in ('es','va')),
  acepta_privacidad boolean not null check (acepta_privacidad),
  consentimiento boolean not null check (consentimiento),
  estado text not null default 'Pendiente' check (estado in ('Pendiente','Activa','Rechazada')),
  intentos_fallidos int not null default 0,
  bloqueada_hasta timestamptz,
  ultimo_acceso timestamptz
);
create unique index if not exists socios_correo_unico on aisab.socios (lower(correo));
alter table aisab.socios enable row level security;

create table if not exists aisab.sesiones (
  token_hash text primary key,
  socio_id bigint not null references aisab.socios(id) on delete cascade,
  creada timestamptz not null default now(),
  caduca timestamptz not null
);
alter table aisab.sesiones enable row level security;

-- ---------- zona de socios ----------
create table if not exists aisab.comunicados (
  id bigint generated always as identity primary key,
  creado timestamptz not null default now(),
  titulo text not null check (char_length(titulo) between 1 and 160),
  texto text not null default '',
  enlace text,
  para text not null default 'Todos' check (para in ('Todos','Afiliados'))
);
alter table aisab.comunicados enable row level security;

create table if not exists aisab.documentos (
  id bigint generated always as identity primary key,
  creado timestamptz not null default now(),
  titulo text not null check (char_length(titulo) between 1 and 160),
  descripcion text,
  nombre_archivo text not null,
  tipo_mime text not null default 'application/pdf',
  tamano int not null check (tamano <= 8 * 1024 * 1024),
  para text not null default 'Todos' check (para in ('Todos','Afiliados')),
  contenido bytea not null
);
alter table aisab.documentos enable row level security;

-- ============================================================
-- Funciones internas
-- ============================================================

create or replace function aisab.comprobar_admin(clave text)
returns void
language plpgsql security definer set search_path = aisab, extensions as $$
begin
  if clave is null or encode(extensions.digest(clave,'sha256'),'hex')
     <> 'c8f70915b4cb236f9fc9b97a33151a34a26b40e45ad7f8474de59f01b624ebd5' then
    raise exception 'clave incorrecta';
  end if;
end $$;

-- devuelve el socio de una sesión válida (o error)
create or replace function aisab.socio_de_token(token text)
returns aisab.socios
language plpgsql security definer set search_path = aisab, extensions as $$
declare s aisab.socios;
begin
  select so.* into s
    from aisab.sesiones se join aisab.socios so on so.id = se.socio_id
   where se.token_hash = encode(extensions.digest(coalesce(token,''),'sha256'),'hex')
     and se.caduca > now();
  if not found then raise exception 'sesion caducada'; end if;
  return s;
end $$;

-- ============================================================
-- Funciones públicas: web
-- ============================================================

-- formulario de sugerencias
create or replace function public.enviar_sugerencia(datos jsonb)
returns void
language plpgsql security definer set search_path = aisab as $$
begin
  if char_length(coalesce(datos->>'texto','')) not between 1 and 5000 then
    raise exception 'texto no valido';
  end if;
  insert into aisab.sugerencias (tipo, area, zona, calle, texto, anonima, nombre, contacto)
  values (
    datos->>'tipo', left(datos->>'area', 120), left(datos->>'zona', 120), left(nullif(datos->>'calle',''), 160),
    datos->>'texto', coalesce((datos->>'anonima')::boolean, true),
    left(nullif(datos->>'nombre',''), 120), left(nullif(datos->>'contacto',''), 160)
  );
end $$;

-- registro de simpatizantes y afiliados
create or replace function public.socio_registrar(datos jsonb)
returns void
language plpgsql security definer set search_path = aisab, extensions as $$
declare
  v_correo text := lower(trim(datos->>'correo'));
  v_clave text := datos->>'clave';
begin
  if char_length(coalesce(v_clave,'')) < 12 or char_length(v_clave) > 200 then
    raise exception 'clave corta';
  end if;
  -- si el correo ya existe no se dice nada (no se delata quién está registrado)
  if exists (select 1 from aisab.socios where lower(correo) = v_correo) then
    return;
  end if;
  insert into aisab.socios (tipo, nombre, apellidos, correo, telefono, clave_hash, idioma, acepta_privacidad, consentimiento)
  values (
    datos->>'tipo', trim(datos->>'nombre'), trim(datos->>'apellidos'), v_correo, trim(datos->>'telefono'),
    extensions.crypt(v_clave, extensions.gen_salt('bf', 10)),
    coalesce(nullif(datos->>'idioma',''), 'es'),
    coalesce((datos->>'acepta_privacidad')::boolean, false),
    coalesce((datos->>'consentimiento')::boolean, false)
  );
end $$;

-- entrar: devuelve un token de sesión (30 días)
create or replace function public.socio_entrar(correo text, clave text)
returns text
language plpgsql security definer set search_path = aisab, extensions as $$
declare
  s aisab.socios;
  v_token text;
begin
  select * into s from aisab.socios where lower(socios.correo) = lower(trim(socio_entrar.correo));
  if not found then
    perform pg_sleep(0.3);
    raise exception 'datos incorrectos';
  end if;
  if s.bloqueada_hasta is not null and s.bloqueada_hasta > now() then
    raise exception 'bloqueada';
  end if;
  if s.clave_hash <> extensions.crypt(coalesce(clave,''), s.clave_hash) then
    update aisab.socios set
      intentos_fallidos = intentos_fallidos + 1,
      bloqueada_hasta = case when intentos_fallidos + 1 >= 5 then now() + interval '15 minutes' end
    where id = s.id;
    raise exception 'datos incorrectos';
  end if;
  update aisab.socios set intentos_fallidos = 0, bloqueada_hasta = null, ultimo_acceso = now() where id = s.id;
  delete from aisab.sesiones where socio_id = s.id and caduca < now();
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into aisab.sesiones (token_hash, socio_id, caduca)
  values (encode(extensions.digest(v_token,'sha256'),'hex'), s.id, now() + interval '30 days');
  return v_token;
end $$;

-- zona de socios: ficha, comunicados y lista de documentos
create or replace function public.socio_datos(token text)
returns jsonb
language plpgsql security definer set search_path = aisab, extensions as $$
declare s aisab.socios;
begin
  s := aisab.socio_de_token(token);
  return jsonb_build_object(
    'nombre', s.nombre, 'apellidos', s.apellidos, 'correo', s.correo, 'telefono', s.telefono,
    'tipo', s.tipo, 'estado', s.estado, 'idioma', s.idioma, 'desde', s.creada,
    'comunicados', case when s.estado = 'Activa' then coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'creado', c.creado, 'titulo', c.titulo, 'texto', c.texto, 'enlace', c.enlace) order by c.creado desc)
        from aisab.comunicados c where c.para = 'Todos' or s.tipo = 'Afiliado'), '[]'::jsonb) else '[]'::jsonb end,
    'documentos', case when s.estado = 'Activa' then coalesce((
      select jsonb_agg(jsonb_build_object('id', d.id, 'creado', d.creado, 'titulo', d.titulo, 'descripcion', d.descripcion, 'nombre_archivo', d.nombre_archivo, 'tamano', d.tamano) order by d.creado desc)
        from aisab.documentos d where d.para = 'Todos' or s.tipo = 'Afiliado'), '[]'::jsonb) else '[]'::jsonb end
  );
end $$;

-- descargar un documento (base64)
create or replace function public.socio_documento(token text, doc_id bigint)
returns jsonb
language plpgsql security definer set search_path = aisab, extensions as $$
declare s aisab.socios; d aisab.documentos;
begin
  s := aisab.socio_de_token(token);
  if s.estado <> 'Activa' then raise exception 'cuenta no activa'; end if;
  select * into d from aisab.documentos where id = doc_id and (para = 'Todos' or s.tipo = 'Afiliado');
  if not found then raise exception 'no existe'; end if;
  return jsonb_build_object('nombre_archivo', d.nombre_archivo, 'tipo_mime', d.tipo_mime, 'base64', encode(d.contenido, 'base64'));
end $$;

create or replace function public.socio_idioma(token text, idioma text)
returns void
language plpgsql security definer set search_path = aisab, extensions as $$
declare s aisab.socios;
begin
  s := aisab.socio_de_token(token);
  if idioma in ('es','va') then update aisab.socios set idioma = socio_idioma.idioma where id = s.id; end if;
end $$;

create or replace function public.socio_cambiar_clave(token text, actual text, nueva text)
returns void
language plpgsql security definer set search_path = aisab, extensions as $$
declare s aisab.socios;
begin
  s := aisab.socio_de_token(token);
  if s.clave_hash <> extensions.crypt(coalesce(actual,''), s.clave_hash) then raise exception 'clave actual incorrecta'; end if;
  if char_length(coalesce(nueva,'')) < 12 or char_length(nueva) > 200 then raise exception 'clave corta'; end if;
  update aisab.socios set clave_hash = extensions.crypt(nueva, extensions.gen_salt('bf', 10)) where id = s.id;
end $$;

create or replace function public.socio_salir(token text)
returns void
language sql security definer set search_path = aisab, extensions as $$
  delete from aisab.sesiones where token_hash = encode(extensions.digest(coalesce(token,''),'sha256'),'hex');
$$;

-- ============================================================
-- Funciones públicas: panel /admin (todas piden la clave)
-- ============================================================

-- sugerencias (mismo nombre y firma que antes, ahora sobre aisab.sugerencias)
drop function if exists public.admin_listar(text);
create function public.admin_listar(clave text)
returns setof aisab.sugerencias
language plpgsql security definer set search_path = aisab, extensions as $$
begin
  perform aisab.comprobar_admin(clave);
  return query select * from aisab.sugerencias order by creada desc;
end $$;

create or replace function public.admin_estado(clave text, sid bigint, nuevo text)
returns void
language plpgsql security definer set search_path = aisab, extensions as $$
begin
  perform aisab.comprobar_admin(clave);
  update aisab.sugerencias set estado = nuevo where id = sid;
end $$;

-- socios
create or replace function public.admin_socios(clave text)
returns jsonb
language plpgsql security definer set search_path = aisab, extensions as $$
begin
  perform aisab.comprobar_admin(clave);
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', id, 'creada', creada, 'tipo', tipo, 'nombre', nombre, 'apellidos', apellidos, 'correo', correo,
    'telefono', telefono, 'idioma', idioma, 'estado', estado, 'ultimo_acceso', ultimo_acceso,
    'bloqueada', bloqueada_hasta is not null and bloqueada_hasta > now()
  ) order by creada desc) from aisab.socios), '[]'::jsonb);
end $$;

create or replace function public.admin_socio_estado(clave text, sid bigint, nuevo text)
returns void
language plpgsql security definer set search_path = aisab, extensions as $$
begin
  perform aisab.comprobar_admin(clave);
  update aisab.socios set estado = nuevo where id = sid;
end $$;

create or replace function public.admin_socio_tipo(clave text, sid bigint, nuevo text)
returns void
language plpgsql security definer set search_path = aisab, extensions as $$
begin
  perform aisab.comprobar_admin(clave);
  update aisab.socios set tipo = nuevo where id = sid;
end $$;

-- contraseña nueva provisional (se enseña una vez al admin) y se cierran sus sesiones
create or replace function public.admin_socio_nueva_clave(clave text, sid bigint)
returns text
language plpgsql security definer set search_path = aisab, extensions as $$
declare v text := translate(encode(extensions.gen_random_bytes(12), 'base64'), '+/=0OIl', 'xyzabcd');
begin
  perform aisab.comprobar_admin(clave);
  update aisab.socios set clave_hash = extensions.crypt(v, extensions.gen_salt('bf', 10)),
         intentos_fallidos = 0, bloqueada_hasta = null where id = sid;
  delete from aisab.sesiones where socio_id = sid;
  return v;
end $$;

-- borrar a un socio (derecho de supresión)
create or replace function public.admin_socio_borrar(clave text, sid bigint)
returns void
language plpgsql security definer set search_path = aisab, extensions as $$
begin
  perform aisab.comprobar_admin(clave);
  delete from aisab.socios where id = sid;
end $$;

-- comunicados
create or replace function public.admin_comunicados(clave text)
returns jsonb
language plpgsql security definer set search_path = aisab, extensions as $$
begin
  perform aisab.comprobar_admin(clave);
  return coalesce((select jsonb_agg(to_jsonb(c) order by c.creado desc) from aisab.comunicados c), '[]'::jsonb);
end $$;

create or replace function public.admin_comunicado_guardar(clave text, datos jsonb)
returns void
language plpgsql security definer set search_path = aisab, extensions as $$
begin
  perform aisab.comprobar_admin(clave);
  if (datos->>'id') is null then
    insert into aisab.comunicados (titulo, texto, enlace, para)
    values (datos->>'titulo', coalesce(datos->>'texto',''), nullif(datos->>'enlace',''), coalesce(datos->>'para','Todos'));
  else
    update aisab.comunicados set titulo = datos->>'titulo', texto = coalesce(datos->>'texto',''),
           enlace = nullif(datos->>'enlace',''), para = coalesce(datos->>'para','Todos')
     where id = (datos->>'id')::bigint;
  end if;
end $$;

create or replace function public.admin_comunicado_borrar(clave text, cid bigint)
returns void
language plpgsql security definer set search_path = aisab, extensions as $$
begin
  perform aisab.comprobar_admin(clave);
  delete from aisab.comunicados where id = cid;
end $$;

-- documentos
create or replace function public.admin_documentos(clave text)
returns jsonb
language plpgsql security definer set search_path = aisab, extensions as $$
begin
  perform aisab.comprobar_admin(clave);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'creado', creado, 'titulo', titulo, 'descripcion', descripcion,
    'nombre_archivo', nombre_archivo, 'tamano', tamano, 'para', para) order by creado desc) from aisab.documentos), '[]'::jsonb);
end $$;

create or replace function public.admin_documento_subir(clave text, datos jsonb)
returns void
language plpgsql security definer set search_path = aisab, extensions as $$
declare v bytea := decode(datos->>'base64', 'base64');
begin
  perform aisab.comprobar_admin(clave);
  insert into aisab.documentos (titulo, descripcion, nombre_archivo, tipo_mime, tamano, para, contenido)
  values (datos->>'titulo', nullif(datos->>'descripcion',''), datos->>'nombre_archivo',
          coalesce(nullif(datos->>'tipo_mime',''), 'application/pdf'), octet_length(v), coalesce(datos->>'para','Todos'), v);
end $$;

create or replace function public.admin_documento_borrar(clave text, did bigint)
returns void
language plpgsql security definer set search_path = aisab, extensions as $$
begin
  perform aisab.comprobar_admin(clave);
  delete from aisab.documentos where id = did;
end $$;

-- ============================================================
-- Permisos: anon solo puede llamar a estas funciones
-- ============================================================
revoke execute on all functions in schema aisab from public, anon, authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'enviar_sugerencia(jsonb)', 'socio_registrar(jsonb)', 'socio_entrar(text,text)', 'socio_datos(text)',
    'socio_documento(text,bigint)', 'socio_idioma(text,text)', 'socio_cambiar_clave(text,text,text)', 'socio_salir(text)',
    'admin_listar(text)', 'admin_estado(text,bigint,text)', 'admin_socios(text)', 'admin_socio_estado(text,bigint,text)',
    'admin_socio_tipo(text,bigint,text)', 'admin_socio_nueva_clave(text,bigint)', 'admin_socio_borrar(text,bigint)',
    'admin_comunicados(text)', 'admin_comunicado_guardar(text,jsonb)', 'admin_comunicado_borrar(text,bigint)',
    'admin_documentos(text)', 'admin_documento_subir(text,jsonb)', 'admin_documento_borrar(text,bigint)'
  ] loop
    execute format('revoke execute on function public.%s from public, authenticated', f);
    execute format('grant execute on function public.%s to anon', f);
  end loop;
end $$;

-- ---------- transición ----------
-- La web publicada hasta ahora inserta en /rest/v1/sugerencias. Esta vista la deja
-- funcionando mientras se publica la nueva (que usa enviar_sugerencia).
-- Cuando la web nueva esté en www.aisab.es:  drop view if exists public.sugerencias;
do $$
begin
  if to_regclass('public.sugerencias') is null then
    create view public.sugerencias as
      select tipo, area, zona, calle, texto, anonima, nombre, contacto from aisab.sugerencias;
    revoke all on public.sugerencias from public, anon, authenticated;
    grant insert on public.sugerencias to anon;
  end if;
end $$;

-- ---------- limpieza de la primera versión (tabla vacía) ----------
drop function if exists public.admin_afiliaciones(text);
drop function if exists public.admin_afiliacion_estado(text, bigint, text);
drop table if exists public.afiliaciones;

-- Extensions and internal schema used by Koda.
--
-- pg_cron + pg_net: scheduled calls to the `push` and `keepalive` Edge Functions.
-- pg_trgm + unaccent: fuzzy product matching (`match_product`).

create extension if not exists pg_trgm with schema extensions;
create extension if not exists unaccent with schema extensions;
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

-- Internal objects (trigger functions, sync state, job helpers). Never exposed through the Data API.
create schema if not exists private;
revoke all on schema private from public;
revoke all on schema private from anon, authenticated;

-- Immutable accent/case-insensitive normalisation, usable in indexes.
create or replace function public.normalize_text(value text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select lower(extensions.unaccent('extensions.unaccent'::regdictionary, coalesce(value, '')));
$$;

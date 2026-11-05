-- Objetos do projeto criados DENTRO dos schemas gerenciados pelo Supabase (auth, storage),
-- que o "supabase db dump" não exporta. Ex.: trigger on_auth_user_created (cria o perfil
-- de cada novo usuário). Saída: comandos SQL prontos para reaplicar após a restauração.
select 'drop trigger if exists ' || quote_ident(t.tgname) || ' on ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname)
       || '; ' || pg_get_triggerdef(t.oid) || ';'
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_namespace n on n.oid = c.relnamespace
join pg_proc p on p.oid = t.tgfoid
join pg_namespace pn on pn.oid = p.pronamespace
where not t.tgisinternal
  and n.nspname in ('auth', 'storage')
  and pn.nspname not in ('auth', 'storage', 'extensions', 'realtime', 'supabase_functions', 'graphql', 'pgbouncer', 'vault')
union all
select 'drop policy if exists ' || quote_ident(pol.polname) || ' on ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname)
       || '; create policy ' || quote_ident(pol.polname) || ' on ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname)
       || case when pol.polpermissive then ' as permissive' else ' as restrictive' end
       || ' for ' || case pol.polcmd when 'r' then 'select' when 'a' then 'insert' when 'w' then 'update' when 'd' then 'delete' else 'all' end
       || ' to ' || coalesce((select string_agg(case when r = 0 then 'public' else quote_ident(pg_get_userbyid(r)) end, ', ') from unnest(pol.polroles) r), 'public')
       || coalesce(' using (' || pg_get_expr(pol.polqual, pol.polrelid) || ')', '')
       || coalesce(' with check (' || pg_get_expr(pol.polwithcheck, pol.polrelid) || ')', '')
       || ';'
from pg_policy pol
join pg_class c on c.oid = pol.polrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'storage' and c.relname in ('objects', 'buckets');

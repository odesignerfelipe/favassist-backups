-- Contagem exata de linhas por tabela (somente leitura).
-- Schemas da aplicação + usuários (auth) + metadados de arquivos (storage).
select table_schema || '.' || table_name,
       (xpath('/row/c/text()',
              query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text::bigint
from information_schema.tables
where table_type = 'BASE TABLE'
  and table_schema in ('public', 'app', 'fav_meta', 'auth', 'storage', 'supabase_functions')
order by 1;

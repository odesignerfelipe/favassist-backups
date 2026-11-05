#!/usr/bin/env bash
# Confere um banco restaurado contra o row-counts.tsv do backup e faz verificações de segurança.
# Uso: TARGET_DB_URL=... scripts/verify.sh <row-counts.tsv>
set -euo pipefail
EXPECTED="${1:?Informe o row-counts.tsv}"
: "${TARGET_DB_URL:?Defina TARGET_DB_URL}"
HERE="$(cd "$(dirname "$0")" && pwd)"
q() { psql "$TARGET_DB_URL" -X -q -v ON_ERROR_STOP=1 -At "$@"; }
fail=0
check() { # descrição, valor obtido, valor esperado
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; else echo "  ✗ $1 (obtido: $2, esperado: $3)"; fail=1; fi
}

echo "Contagem de linhas por tabela:"
ACTUAL="$(mktemp)"
trap 'rm -f "$ACTUAL"' EXIT
q -F $'\t' -f "$HERE/live-counts.sql" > "$ACTUAL"
tables=0; mismatches=0
while IFS=$'\t' read -r table expected; do
  tables=$((tables + 1))
  actual="$(awk -F'\t' -v t="$table" '$1 == t { print $2 }' "$ACTUAL")"
  if [ "${actual:-ausente}" != "$expected" ]; then
    echo "  ✗ $table: obtido ${actual:-ausente}, esperado $expected"
    mismatches=$((mismatches + 1))
  fi
done < "$EXPECTED"
total="$(awk -F'\t' '{s+=$2} END {print s+0}' "$EXPECTED")"
if [ "$mismatches" = 0 ]; then echo "  ✓ $tables tabelas, $total linhas — todas conferem"; else fail=1; fi

echo "Estrutura e segurança:"
check "migrações do FAV registradas" "$(q -c "select count(*) > 0 from fav_meta.migrations")" "t"
check "RLS ativo em todas as tabelas públicas" "$(q -c "select count(*) from pg_tables where schemaname = 'public' and not rowsecurity")" "0"
check "trigger on_auth_user_created presente" "$(q -c "select count(*) from pg_trigger where tgname = 'on_auth_user_created' and not tgisinternal")" "1"
check "trigger de auditoria das atividades presente" "$(q -c "select count(*) > 0 from pg_trigger t join pg_class c on c.oid = t.tgrelid where c.relname = 'activities' and not t.tgisinternal")" "t"
check "todo usuário tem perfil" "$(q -c "select count(*) from auth.users u left join public.profiles p on p.id = u.id where p.id is null")" "0"

# Isolamento: visitante anônimo não lê nada; administrador vê as empresas pelas políticas de RLS
anon_out="$(q -c "begin; set local role anon; select count(*) from public.companies; rollback;" 2>&1 || true)"
anon="$(printf '%s\n' "$anon_out" | tail -n 1)"
if printf '%s' "$anon_out" | grep -q 'permission denied' || [ "$anon" = 0 ]; then anon=bloqueado; fi
check "visitante anônimo não lê empresas" "$anon" "bloqueado"
admin="$(q -c "select id from public.profiles where platform_role = 'favis_admin' and active limit 1")"
if [ -n "$admin" ]; then
  seen="$(q -c "begin; set local role authenticated; select set_config('request.jwt.claims', '{\"sub\":\"$admin\",\"role\":\"authenticated\"}', true); select count(*) from public.companies; rollback;" | tail -n 1)"
  check "administrador vê todas as empresas via RLS" "$seen" "$(q -c "select count(*) from public.companies")"
fi

exit $fail

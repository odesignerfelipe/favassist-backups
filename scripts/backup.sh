#!/usr/bin/env bash
# Gera um backup criptografado do banco do Supabase (FAV Assist).
#
# Uso:  SUPABASE_DB_URL=... BACKUP_PASSPHRASE=... scripts/backup.sh <pasta-de-saída>
#
# Conteúdo (formato oficial do Supabase para migrar/restaurar projetos):
#   roles.sql   — papéis personalizados
#   schema.sql  — estrutura (tabelas, funções, RLS, triggers) dos schemas do projeto
#   data.sql    — dados de todos os schemas, inclusive auth (usuários) e storage (metadados)
#   managed-extras.sql — triggers/políticas do projeto em auth/storage (o dump do Supabase omite)
#   row-counts.tsv — linhas por tabela contidas em data.sql (conferido no teste de restauração)
#   live-counts.tsv — contagem no banco no momento do backup (informativo)
#   SHA256SUMS, info.txt
# Saída: <pasta>/fav-backup-<data>.tar.gz.gpg (AES-256, senha em BACKUP_PASSPHRASE).
# Nenhum arquivo em claro permanece no disco ao final.
set -euo pipefail

: "${SUPABASE_DB_URL:?Defina SUPABASE_DB_URL}"
: "${BACKUP_PASSPHRASE:?Defina BACKUP_PASSPHRASE}"
if [ "${#BACKUP_PASSPHRASE}" -lt 20 ]; then
  echo "BACKUP_PASSPHRASE muito curta (mínimo 20 caracteres)." >&2
  exit 1
fi

OUT="${1:-out}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SUPABASE="${SUPABASE_BIN:-supabase}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="fav-backup-$STAMP"

mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
D="$WORK/$NAME"
mkdir -p "$D"

echo "→ Exportando papéis, estrutura e dados…"
$SUPABASE db dump --db-url "$SUPABASE_DB_URL" -f "$D/roles.sql" --role-only
$SUPABASE db dump --db-url "$SUPABASE_DB_URL" -f "$D/schema.sql"
# Tabelas internas do Supabase em que o usuário "postgres" não pode inserir (ex.: storage.vector_indexes)
# quebrariam a restauração; ficam fora do dump de dados. Se alguma tiver dados, o backup falha para revisão.
EXCLUDE="$(psql "$SUPABASE_DB_URL" -X -At -c "
  select string_agg(n.nspname || '.' || c.relname, ',' order by 1)
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where c.relkind = 'r' and n.nspname in ('auth', 'storage', 'supabase_functions')
    and c.relname not in ('schema_migrations', 'migrations')
    and not has_table_privilege(current_user, c.oid, 'INSERT')")"
for t in ${EXCLUDE//,/ }; do
  rows="$(psql "$SUPABASE_DB_URL" -X -At -c "select count(*) from $t")"
  if [ "$rows" != 0 ]; then echo "A tabela $t tem $rows linha(s) mas não pode ser restaurada pelo usuário postgres. Revise o backup." >&2; exit 1; fi
done
$SUPABASE db dump --db-url "$SUPABASE_DB_URL" -f "$D/data.sql" --use-copy --data-only ${EXCLUDE:+-x "$EXCLUDE"}

psql "$SUPABASE_DB_URL" -X -q -v ON_ERROR_STOP=1 -At -f "$HERE/managed-extras.sql" > "$D/managed-extras.sql"

echo "→ Conferindo o conteúdo exportado…"
"$HERE/count-dump.sh" "$D/data.sql" > "$D/row-counts.tsv"
psql "$SUPABASE_DB_URL" -X -q -v ON_ERROR_STOP=1 -At -F $'\t' -f "$HERE/live-counts.sql" > "$D/live-counts.tsv"

grep -q 'CREATE TABLE IF NOT EXISTS "public"."activities"' "$D/schema.sql" || { echo "schema.sql sem a tabela activities" >&2; exit 1; }
grep -q '^COPY "auth"."users"' "$D/data.sql" || { echo "data.sql sem auth.users" >&2; exit 1; }
grep -q 'on_auth_user_created' "$D/managed-extras.sql" || { echo "managed-extras.sql sem o trigger on_auth_user_created" >&2; exit 1; }

{
  echo "backup: $NAME"
  echo "criado_em_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "postgres: $(psql "$SUPABASE_DB_URL" -X -At -c 'show server_version')"
  echo "supabase_cli: $($SUPABASE --version)"
  echo "tabelas_com_dados: $(awk -F'\t' '$2>0' "$D/row-counts.tsv" | wc -l)"
  echo "linhas_total: $(awk -F'\t' '{s+=$2} END {print s+0}' "$D/row-counts.tsv")"
  echo "tabelas_internas_vazias_excluidas: ${EXCLUDE:-nenhuma}"
} > "$D/info.txt"
(cd "$D" && sha256sum ./*.sql ./*.tsv info.txt > SHA256SUMS)

echo "→ Compactando e criptografando (AES-256)…"
tar -C "$WORK" -czf - "$NAME" |
  gpg --batch --yes --quiet --pinentry-mode loopback \
    --passphrase-file <(printf '%s' "$BACKUP_PASSPHRASE") \
    --symmetric --cipher-algo AES256 --s2k-digest-algo SHA512 --s2k-mode 3 --s2k-count 65011712 \
    -o "$OUT/$NAME.tar.gz.gpg"

cp "$D/info.txt" "$OUT/$NAME.info.txt"
cat "$D/info.txt"
echo "✓ Backup: $OUT/$NAME.tar.gz.gpg ($(du -h "$OUT/$NAME.tar.gz.gpg" | cut -f1))"

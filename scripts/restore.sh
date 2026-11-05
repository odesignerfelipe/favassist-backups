#!/usr/bin/env bash
# Restaura um backup do FAV Assist em um banco Supabase NOVO E VAZIO
# (projeto novo no Supabase, ou o banco local do "supabase start" no teste de restauração).
#
# Uso:  BACKUP_PASSPHRASE=... TARGET_DB_URL=... scripts/restore.sh <arquivo.tar.gz.gpg>
#
# ATENÇÃO: nunca aponte TARGET_DB_URL para o banco de produção em uso.
# O script recusa bancos que já tenham as tabelas do FAV Assist.
set -euo pipefail

FILE="${1:?Informe o arquivo .tar.gz.gpg}"
: "${BACKUP_PASSPHRASE:?Defina BACKUP_PASSPHRASE}"
: "${TARGET_DB_URL:?Defina TARGET_DB_URL (banco NOVO e vazio)}"
HERE="$(cd "$(dirname "$0")" && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "→ Descriptografando e conferindo a integridade…"
gpg --batch --quiet --pinentry-mode loopback --passphrase-file <(printf '%s' "$BACKUP_PASSPHRASE") -d "$FILE" | tar -xz -C "$WORK"
D="$(find "$WORK" -mindepth 1 -maxdepth 1 -type d -name 'fav-backup-*' | head -1)"
(cd "$D" && sha256sum --quiet -c SHA256SUMS)
cat "$D/info.txt"

existing="$(psql "$TARGET_DB_URL" -X -At -c "select count(*) from information_schema.tables where table_schema = 'public' and table_name in ('companies', 'activities', 'profiles')")"
if [ "$existing" != "0" ]; then
  echo "O banco de destino já contém tabelas do FAV Assist. Restauração cancelada (use um banco novo e vazio)." >&2
  exit 1
fi

echo "→ Restaurando papéis, estrutura e dados (transação única)…"
psql "$TARGET_DB_URL" -X -q --single-transaction -v ON_ERROR_STOP=1 \
  --file "$D/roles.sql" \
  --file "$D/schema.sql" \
  --command 'SET session_replication_role = replica' \
  --file "$D/data.sql" > "$WORK/restore.log"

echo "→ Reaplicando triggers/políticas do projeto em auth/storage…"
PGOPTIONS="-c client_min_messages=warning" psql "$TARGET_DB_URL" -X -q --single-transaction -v ON_ERROR_STOP=1 --file "$D/managed-extras.sql" >> "$WORK/restore.log"

echo "→ Verificando…"
"$HERE/verify.sh" "$D/row-counts.tsv"
echo "✓ Restauração concluída e verificada."
echo "  Lembrete: fotos e vídeos (Supabase Storage) não fazem parte deste backup — só os metadados."

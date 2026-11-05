#!/usr/bin/env bash
# Teste completo SEM tocar a produção:
#   1. sobe um Supabase local e instala o FAV Assist (migrações + usuários + dados de demonstração)
#   2. gera o backup criptografado com scripts/backup.sh
#   3. APAGA o Supabase local e sobe um novo, vazio
#   4. restaura com scripts/restore.sh e verifica (contagens, RLS, triggers)
#   5. faz login com o administrador no Auth restaurado (prova que usuários e senhas voltaram)
#
# Uso: FAV_REPO=<checkout do favassist> scripts/selftest.sh
set -euo pipefail
: "${FAV_REPO:?Defina FAV_REPO (checkout de odesignerfelipe/favassist)}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
SUPABASE="${SUPABASE_BIN:-supabase}"
EXCLUDE_SERVICES="realtime,imgproxy,mailpit,studio,edge-runtime,logflare,vector,supavisor,postgres-meta,postgrest"
OUT="$(mktemp -d)"
export BACKUP_PASSPHRASE="selftest-$(openssl rand -hex 24)"
ADMIN_EMAIL="admin@selftest.favassist.dev"
ADMIN_PASSWORD="Selftest-$(openssl rand -hex 8)"

cd "$ROOT"
status() { $SUPABASE status -o env 2>/dev/null | sed -n "s/^$1=\"\(.*\)\"$/\1/p"; }
login() {
  curl -s -o /dev/null -w '%{http_code}' -X POST "$(status API_URL)/auth/v1/token?grant_type=password" \
    -H "apikey: $(status PUBLISHABLE_KEY)" -H 'content-type: application/json' \
    -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}"
}

echo "== 1. Banco de origem (Supabase local com o FAV Assist)"
$SUPABASE stop --no-backup >/dev/null 2>&1 || true
$SUPABASE start -x "$EXCLUDE_SERVICES" >/dev/null
DB_URL="$(status DB_URL)"
API_URL="$(status API_URL)"; PUB_KEY="$(status PUBLISHABLE_KEY)"; SECRET_KEY="$(status SECRET_KEY)"
(
  cd "$FAV_REPO/apps/api"
  export DATABASE_URL="$DB_URL" AUTH_PROVIDER=supabase NODE_ENV=development \
    SUPABASE_URL="$API_URL" SUPABASE_ANON_KEY="$PUB_KEY" SUPABASE_SERVICE_ROLE_KEY="$SECRET_KEY"
  npx tsx src/db/migrate.ts
  SEED_ADMIN_EMAIL="$ADMIN_EMAIL" SEED_ADMIN_PASSWORD="$ADMIN_PASSWORD" npx tsx src/scripts/seed-admin.ts
  npx tsx src/scripts/seed-demo.ts
)
KEY="$(status SECRET_KEY)"
curl -sf -X POST "$(status API_URL)/storage/v1/bucket" -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
  -H 'content-type: application/json' -d '{"id":"evidencias","name":"evidencias","public":false}' >/dev/null
printf 'arquivo de teste' | curl -sf -X POST "$(status API_URL)/storage/v1/object/evidencias/selftest/a.txt" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H 'content-type: text/plain' --data-binary @- >/dev/null
[ "$(login)" = 200 ] || { echo "Login na origem falhou" >&2; exit 1; }
echo "  ✓ origem pronta (login do administrador OK)"

echo "== 2. Backup"
SUPABASE_DB_URL="$DB_URL" "$HERE/backup.sh" "$OUT"

echo "== 3. Apagando a origem e subindo um Supabase novo e vazio"
$SUPABASE stop --no-backup >/dev/null
$SUPABASE start -x "$EXCLUDE_SERVICES" >/dev/null
[ "$(psql "$(status DB_URL)" -X -At -c "select count(*) from auth.users")" = 0 ] || { echo "Destino não está vazio" >&2; exit 1; }
[ "$(login)" != 200 ] || { echo "Login funcionou antes da restauração?!" >&2; exit 1; }
echo "  ✓ destino vazio (login recusado)"

echo "== 4. Restauração"
TARGET_DB_URL="$(status DB_URL)" "$HERE/restore.sh" "$OUT"/fav-backup-*.tar.gz.gpg

echo "== 5. Login no Auth restaurado"
code="$(login)"
[ "$code" = 200 ] || { echo "  ✗ login após restauração: HTTP $code" >&2; exit 1; }
echo "  ✓ administrador entra com a mesma senha após a restauração"

echo "== 6. Senha errada não abre o backup"
if BACKUP_PASSPHRASE="senha-errada-0123456789" TARGET_DB_URL="postgresql://ninguem@127.0.0.1:1/x" "$HERE/restore.sh" "$OUT"/fav-backup-*.tar.gz.gpg >/dev/null 2>&1; then
  echo "  ✗ backup abriu com senha errada" >&2; exit 1
fi
echo "  ✓ recusado"

$SUPABASE stop --no-backup >/dev/null
rm -rf "$OUT"
echo "✓ TESTE COMPLETO APROVADO"

# FAV Assist — Backups do banco

Repositório **privado** com a rotina de backup do banco do FAV Assist (Supabase).
Não contém dados nem credenciais. Os backups ficam como *artifacts* criptografados do GitHub Actions.

## O que é feito

| Item | Como |
|---|---|
| Frequência | Diária, às 03:17 (Brasília), mais execução manual a qualquer momento (ex.: antes de cada publicação) |
| Conteúdo | Papéis, estrutura (tabelas, funções, RLS, triggers) e **todos os dados**, inclusive usuários e senhas (hash) do Supabase Auth e metadados dos arquivos. Inclui os triggers do projeto em `auth`/`storage`, que o dump padrão do Supabase omite |
| Criptografia | AES-256 (GnuPG, chave derivada da senha `BACKUP_PASSPHRASE` com SHA-512 e 65 milhões de iterações). Nenhum arquivo em claro é guardado |
| Onde fica | GitHub (fora da VPS e fora do Supabase), neste repositório privado |
| Retenção | Diários: 30 dias. Semanais (domingo): 90 dias. Expiram sozinhos |
| Integridade | SHA-256 de cada arquivo, conferido na restauração |
| Teste de restauração | Semanal (domingo), automático: restaura o backup num Supabase temporário e confere tabela por tabela, RLS e triggers. Também mensal: autoteste completo com dados fictícios (inclui login após restaurar) |
| Alerta | Falha abre uma *issue* neste repositório — o GitHub envia e-mail ao dono |

**Não inclui:** os arquivos de fotos e vídeos (Supabase Storage) — apenas os metadados. Planejado para uma segunda etapa.

## Ativação (requer autorização)

1. *Settings → Secrets and variables → Actions → Secrets*:
   - `SUPABASE_DB_URL`: string de conexão do **Session pooler** do Supabase (*Project Settings → Database → Connect → Session pooler*, porta 5432). Os servidores do GitHub não têm IPv6, por isso a conexão direta não funciona. Pode ser o mesmo valor do `DATABASE_URL` configurado no Easypanel. **Não redefina a senha do banco**: isso derrubaria o sistema em produção.
   - `BACKUP_PASSPHRASE`: senha longa (mínimo 20 caracteres; recomendado gerar com `openssl rand -base64 32`). **Guarde-a também fora do GitHub** (gerenciador de senhas). Sem ela, nenhum backup pode ser aberto.
2. *Actions → Backup do banco (produção) → Run workflow* (marque "Testar a restauração"). Confira que os dois jobs ficaram verdes.
3. *Settings → Secrets and variables → Actions → Variables*: crie `BACKUP_ENABLED` = `true` para ligar o agendamento diário.

Para pausar: mude `BACKUP_ENABLED` para `false`.

## Restaurar (desastre)

> Sempre em um projeto Supabase **novo e vazio**. O script recusa bancos que já tenham as tabelas do FAV Assist.

1. Baixe o artifact desejado em *Actions → (execução) → Artifacts* e descompacte o `.zip`.
2. Crie um projeto novo no Supabase (mesma região) e copie a string do Session pooler.
3. Em um computador com Docker e Supabase CLI 3.0.0 (ou `npx supabase@3.0.0`), `psql` e `gpg`:

```bash
BACKUP_PASSPHRASE='...' TARGET_DB_URL='postgresql://...' scripts/restore.sh fav-backup-AAAAMMDDTHHMMSSZ.tar.gz.gpg
```

4. Atualize no Easypanel `DATABASE_URL`, `SUPABASE_URL` e as chaves do novo projeto, e reimplante. Os usuários entram com as mesmas senhas.

Para só abrir o conteúdo (sem restaurar):

```bash
gpg -d fav-backup-....tar.gz.gpg | tar -xz
```

## Testar sem produção

```bash
FAV_REPO=../favassist scripts/selftest.sh
```

Sobe um Supabase local, instala o FAV Assist, faz backup, apaga tudo, restaura, verifica e faz login.

## Custos

R$ 0 no plano gratuito do GitHub (repositório privado: 2.000 min/mês de Actions e 500 MB de armazenamento de artifacts).
Estimativa: ~3 min por backup diário + ~5 min por teste semanal + ~6 min por autoteste mensal ≈ **120 min/mês**; backups de poucos MB cada (≈ 30 diários + 13 semanais).
Se o banco crescer além de ~10 MB por backup comprimido, revisar a retenção.

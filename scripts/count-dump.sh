#!/usr/bin/env bash
# Conta as linhas de cada tabela em um data.sql gerado com --use-copy.
# Saída: schema.tabela<TAB>linhas (ordenado). No formato COPY texto, cada linha é um registro.
set -euo pipefail
awk '
  /^COPY "[^"]+"\."[^"]+"/ {
    match($0, /^COPY "[^"]+"\."[^"]+"/)
    t = substr($0, 7, RLENGTH - 6); gsub(/"/, "", t)
    inside = 1; n = 0; next
  }
  inside && $0 == "\\." { counts[t] += n; inside = 0; next }
  inside { n++ }
  END { for (t in counts) printf "%s\t%d\n", t, counts[t] }
' "$1" | LC_ALL=C sort

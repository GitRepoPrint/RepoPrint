#!/usr/bin/env sh
# O catálogo de tecnologias existe em duas cópias (backend e frontend). Têm de ser iguais.
# Uso: scripts/check-catalog-sync.sh   (a partir da raiz do repositório, com os dois submódulos descarregados)
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
backend="$root/RepoPrint-Backend/app/services/dfd_catalog.json"
frontend="$root/RepoPrint-Frontend/src/lib/dfd/catalog.json"
if cmp -s "$backend" "$frontend"; then
  echo "catálogo em sincronia"
else
  echo "O catálogo do backend e o do frontend são diferentes:" >&2
  echo "  $backend" >&2
  echo "  $frontend" >&2
  echo "Copie a versão certa para a outra e volte a gerar o ficheiro de paridade (ver docs/dfd-schema.md)." >&2
  exit 1
fi

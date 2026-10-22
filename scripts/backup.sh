#!/usr/bin/env bash
# Dumps roles, schema and data of the Koda database into backups/ (ignored by git).
# Run it BEFORE every `supabase db push`.
#
# Target selection:
#   SUPABASE_DB_URL set  -> that database (e.g. the `koda` session-pooler URL)
#   --local              -> the local Docker stack
#   otherwise            -> the linked project (`supabase link`)
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -n "${SUPABASE_DB_URL:-}" ]]; then
  target=(--db-url "$SUPABASE_DB_URL")
elif [[ "${1:-}" == "--local" ]]; then
  target=(--local)
else
  target=(--linked)
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dir="backups/$stamp"
mkdir -p "$dir"

supabase db dump "${target[@]}" --role-only -f "$dir/roles.sql"
supabase db dump "${target[@]}" -f "$dir/schema.sql"
supabase db dump "${target[@]}" --data-only --use-copy -f "$dir/data.sql"

echo "Backup written to $dir"
ls -lh "$dir"

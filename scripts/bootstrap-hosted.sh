#!/usr/bin/env bash
# One-time bootstrap of the hosted `koda` project, run by a human (it handles secrets that must
# never pass through an agent):
#   1. Function secrets: APNs config, APNs .p8 (read straight from the file) and two random
#      internal secrets, mirrored into Vault for the pg_cron jobs.
#   2. GitHub Actions secrets of koda-laboratory/koda-backend for the keepalive fallback.
#   3. The two household accounts (passwords are prompted, never stored).
#   4. The Notion import (../notion-data/comidita.json) into the new household.
#
# Usage: scripts/bootstrap-hosted.sh [path/to/AuthKey_XXXX.p8]
# Run it once: a second run rotates the secrets fine but would create another "Casa" household.
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT_REF="vccllqqmrebbdfpekoud"
SUPABASE_URL="https://${PROJECT_REF}.supabase.co"
APNS_P8="${1:-../koda-app-ios-macos-certs/AuthKey_38H2AWSNST.p8}"
GITHUB_REPO="koda-laboratory/koda-backend"

[[ -f "$APNS_P8" ]] || { echo "APNs key not found: $APNS_P8" >&2; exit 1; }

echo "==> Linking ${PROJECT_REF}"
supabase link --project-ref "$PROJECT_REF" >/dev/null

echo "==> Function secrets"
supabase secrets set --project-ref "$PROJECT_REF" \
  APNS_KEY_ID=38H2AWSNST APNS_TEAM_ID=MUDCX7X324 APNS_BUNDLE_ID=com.kodalabs.app >/dev/null
supabase secrets set --project-ref "$PROJECT_REF" APNS_PRIVATE_KEY="$(cat "$APNS_P8")" >/dev/null
push_secret="$(openssl rand -hex 32)"
keepalive_secret="$(openssl rand -hex 32)"
supabase secrets set --project-ref "$PROJECT_REF" \
  PUSH_INTERNAL_SECRET="$push_secret" KEEPALIVE_SECRET="$keepalive_secret" >/dev/null

echo "==> Vault (scheduled jobs)"
supabase db query --linked >/dev/null "
do \$\$
declare
  v record;
begin
  for v in select * from (values
    ('koda_push_secret', '${push_secret}'),
    ('koda_keepalive_secret', '${keepalive_secret}')
  ) as t (name, value)
  loop
    if exists (select 1 from vault.secrets where name = v.name) then
      perform vault.update_secret((select id from vault.secrets where name = v.name), v.value);
    else
      perform vault.create_secret(v.value, v.name);
    end if;
  end loop;
end;
\$\$;"

echo "==> GitHub Actions secrets (${GITHUB_REPO})"
gh secret set KODA_FUNCTIONS_URL -R "$GITHUB_REPO" --body "${SUPABASE_URL}/functions/v1"
gh secret set KEEPALIVE_SECRET -R "$GITHUB_REPO" --body "$keepalive_secret"
unset push_secret keepalive_secret

echo "==> Secret key for the admin scripts"
SUPABASE_SECRET_KEY="$(
  supabase projects api-keys --project-ref "$PROJECT_REF" --reveal -o json | python3 -c '
import json, sys
data = json.load(sys.stdin)
keys = data if isinstance(data, list) else data.get("keys", data.get("api_keys", []))
def pick(pred):
    for k in keys:
        if pred(k) and (k.get("api_key") or "").strip():
            return k["api_key"]
secret = pick(lambda k: k.get("type") == "secret") or pick(lambda k: k.get("name") == "service_role")
if not secret:
    sys.exit("no secret/service_role key found")
print(secret)
'
)"
export SUPABASE_URL SUPABASE_SECRET_KEY

echo "==> Accounts (you will be asked for each password)"
owner_output="$(deno run --allow-env --allow-net scripts/create-user.ts \
  --email espeso86@gmail.com --name "Manu" --household-name "Casa" --role owner | tee /dev/stderr)"
household_id="$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' <<<"$owner_output" | tail -1)"
deno run --allow-env --allow-net scripts/create-user.ts \
  --email olga.cardielpal@gmail.com --name "Olga" --household-id "$household_id" --role member

echo "==> Notion import into household ${household_id}"
deno run --allow-env --allow-read --allow-net scripts/import-notion.ts --household-id "$household_id"

unset SUPABASE_SECRET_KEY
echo "==> Done. Household: ${household_id}"

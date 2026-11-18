#!/usr/bin/env sh
# Erzeugt einen eingeschraenkten LiteLLM-Virtual-Key fuer den pi-Container.
#
# Warum: pi bekommt bisher den MASTER-Key. Damit kann der Agent (und alles, was
# per Prompt-Injection in ein Repo geraetet) alle Modelle nutzen, alle
# Provider-Keys auslesen und unbegrenzt Geld ausgeben. Ein Virtual Key ist auf
# 4 Modelle, rpm/tpm und ein Budget begrenzt.
#
# Ablauf: LiteLLM-Stack starten, einmal ausfuehren, Ausgabe in .env eintragen,
# pi neu starten.
#
#   docker compose up -d litellm
#   ./scripts/make-pi-key.sh
#   # -> LITELLM_PROXY_TOKEN=sk-... in .env schreiben
#   docker compose up -d
#
set -eu

: "${LITELLM_MASTER_KEY:?LITELLM_MASTER_KEY muss gesetzt sein (z.B. via .env)}"
PROXY="${LITELLM_URL:-http://127.0.0.1:4000}"

# jq ist optional; ohne jq geben wir die rohe Antwort aus.
payload='{
  "key_alias": "pi-sandbox",
  "models": [
    "glm-5.3-flash",
    "qwen3.5-397b-a17b",
    "deepseek-v4.1-flash-1017-uncensored",
    "deepseek-v4.1-flash-uncensored-fp8"
  ],
  "rpm_limit": 120,
  "max_budget": 10,
  "budget_duration": "30d",
  "metadata": {"created_by": "scripts/make-pi-key.sh"}
}'

echo "-> POST ${PROXY}/key/generate" >&2
resp=$(curl -sS --fail-with-body \
  -X POST "${PROXY}/key/generate" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d "$payload")

if command -v jq >/dev/null 2>&1; then
  key=$(printf '%s' "$resp" | jq -r '.key')
else
  key=$(printf '%s' "$resp" | sed -n 's/.*"key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
fi

if [ -z "$key" ] || [ "$key" = "null" ]; then
  echo "FEHLER: kein Key in Antwort:" >&2
  printf '%s\n' "$resp" >&2
  exit 1
fi

cat <<EOF

Virtual Key erzeugt. In .env eintragen (NICHT committen):

  LITELLM_PROXY_TOKEN=${key}

Danach: docker compose up -d --force-recreate pi

Hinweis: Der Key liegt in LiteLLM nur im Speicher, solange kein Postgres
konfiguriert ist - nach einem LiteLLM-Neustart neu erzeugen.
EOF

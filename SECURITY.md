# Security-Hinweise

Sandbox fuer Pi + LiteLLM. Ziel: Agent ohne Internet, Provider-Keys und
Geldbeutel ausserhalb der Reichweite des Agenten.

## Bedrohungsmodell
Prompt-Injection aus Repo-Dateien, kompromittierte Abhaengigkeiten im
Workspace, entwendeter Proxy-Token, Kosten-Runaway, Container-Escape.

## Umgesetzt
- `pi` ohne Internet (`internal: true`, nur LiteLLM erreichbar).
- `pi` laeuft als UID 1000, read-only Rootfs, `cap_drop: ALL`,
  `no-new-privileges`, pids/mem-Limits, Log-Rotation.
- LiteLLM gleich gehaertet; nur dieser Container hat Egress und Provider-Keys.
- LiteLLM-Port nur auf `127.0.0.1`.
- `pi` bekommt einen **Virtual Key** (4 Modelle, rpm/tpm, Budget) statt des
  Master-Keys - siehe `scripts/make-pi-key.sh`.
- Globale Notbremse `max_budget` in `litellm-config.yaml`.
- Sessions/Secrets in `.gitignore`; Session-Dateien `0600`, Verzeichnisse `0700`.
- Images/Versionen gepinnt, `npm --ignore-scripts`.

## Restrisiken
- **Virtual Key nur im Speicher:** ohne Postgres sind Keys nach LiteLLM-Neustart
  weg -> neu erzeugen. Fuer Dauerbetrieb Postgres anbinden.
- **Kein Digest-Pin:** `main-v1.55.8` ist versions-, nicht digest-gepinnt.
  `docker buildx imagetools inspect ghcr.io/berriai/litellm:main-v1.55.8` liefert
  den Digest - eintragen, dann ist der Tag nur Doku.
- **LiteLLM ist SSRF-Pivot:** `api_base` wird vom Proxy gefetcht; wer Config
  schreiben darf, kann interne Ziele ansprechen.
- **Sessions auf dem Host:** enthalten echte Dateiinhalte und Tool-Output.
  Bei Weitergabe des Repos pruefen.
- **Kein Secret-Scanning** in Tool-Output; Keys im Workspace bleiben sichtbar.
- **`drop_params: true`** verschluckt Tippfehler in Modellparametern.
- `read_only`-Rootfs bricht `npm install` im Container - dafuer gibt es
  `/home/node/.npm` als tmpfs (nicht persistent).

## Betrieb
```sh
cp .env.example .env          # Keys eintragen
docker compose up -d litellm
./scripts/make-pi-key.sh      # LITELLM_PROXY_TOKEN in .env
docker compose up -d
docker compose exec pi env | grep -c MASTER   # sollte 0 sein
```

## Pruefen
```sh
docker compose config | grep -E "read_only|cap_drop|user:"
docker compose exec pi sh -c 'wget -qO- https://example.com || echo "kein Internet (ok)"'
docker compose exec pi curl -s -H "Authorization: Bearer $LITELLM_PROXY_TOKEN" \
  http://litellm:4000/model/info | head
```

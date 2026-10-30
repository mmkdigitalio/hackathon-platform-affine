# AFFiNE auf der MMK-Plattform: Runbook

Für Betriebsagent und Menschen im Bereitschaftsdienst. Gilt für AFFiNE im Namespace `affine-<env>` (zurzeit `affine-staging`), ausgerollt über `app-deploy.yml` aus [`mmkdigitalio/hackathon-platform-team`](https://github.com/mmkdigitalio/hackathon-platform-team). Chart, Smoke-Test und Runbook stammen aus [`mmkdigitalio/hackathon-platform-affine`](https://github.com/mmkdigitalio/hackathon-platform-affine).

Erlaubte Aktionen: **`restart`** und **`redeploy`**. Alles andere ist Sache von Menschen (siehe [Grenzen](#grenzen)).

## Aufbau

| Objekt | Name | Herkunft | Inhalt |
| --- | --- | --- | --- |
| Deployment | `affine` | Chart | 1 Pod, Strategie `Recreate`; Init-Container `migrate`, Container `affine` |
| Service | `affine` | Chart | Port 3010 |
| ConfigMap | `affine-config` | Chart | `config.json` (Registrierung aus, Indexer aus) |
| PVC | `affine-data` | App-Stack | `storage/` (Anhänge), `config/private.key` (Server-Schlüssel) |
| Secret | `affine-platform` | App-Stack | `DATABASE_URL`, `REDIS_SERVER_HOST`, `REDIS_SERVER_PASSWORD`, `SMOKE_USER_PASSWORD` |
| Deployment | `affine-redis` | App-Stack | Cache und Warteschlange, ohne Persistenz |
| Datenbank | `affine` | App-Stack | auf dem Foundation-PostgreSQL-Server, Login `affine` |
| Ingress | `affine` | App-Stack | `https://affine.<baseDomain>` → Service `affine:3010` |

Ablauf eines Pod-Starts: `migrate` führt `self-host-predeploy.js` aus (Prisma- und Datenmigrationen, legt beim ersten Start `private.key` an), danach startet `affine` den Server. `/info` liefert 200, sobald der Server Anfragen annimmt; Startup-Probe bis 5 Minuten, danach Readiness und Liveness auf `/info`.

## Diagnose

```bash
NS=affine-staging
kubectl -n $NS get deploy,pods,pvc -o wide
kubectl -n $NS describe pod -l app.kubernetes.io/instance=affine        # Events: Probes, Volume, Image
kubectl -n $NS logs deploy/affine -c migrate --tail=100                  # Migrationen
kubectl -n $NS logs deploy/affine -c affine --tail=200                   # Server
kubectl -n $NS logs deploy/affine -c affine --previous --tail=100        # letzter Absturz
kubectl -n $NS get deploy affine-redis; kubectl -n $NS logs deploy/affine-redis --tail=50
helm -n $NS history affine                                               # Release-Verlauf
git log --oneline -5 -- platform/environments/staging/affine.yaml        # im Plattform-Repository
```

Der Smoke-Test schreibt als letzte Zeile ein JSON mit `evidence`; `check` nennt die fehlgeschlagene Teilprüfung (`availability`, `login`, `document`, `document-write`, `attachment`).

## Symptome und Maßnahmen

| Symptom | Diagnose | Maßnahme |
| --- | --- | --- |
| Verfügbarkeitsalarm, keine Pods, `READY 0/0` | `spec.replicas` des Deployments ist 0 | `redeploy` setzt die Replica-Zahl auf den Sollzustand |
| Pod hängt, Server antwortet nicht, Logs ohne klare Ursache | Liveness schlägt fehl oder Prozess blockiert | `restart`; wirkt es nicht, `redeploy` |
| `affine` in `CrashLoopBackOff`, Log `FATAL ERROR: Reached heap limit ... JavaScript heap out of memory` | `NODE_OPTIONS` (Wert `values.affine.nodeOptions`) zu klein; Konfigurationsfehler im Sollzustand | **Nicht reparierbar** mit `restart`/`redeploy`. `needs_attention` mit dem letzten Commit auf `platform/environments/staging/affine.yaml` |
| `OOMKilled` in `describe pod` | Speicherlimit aus `sizes.resources` zu klein für `nodeOptions` | `needs_attention`: Sollzustand anpassen (Mensch) |
| Init-Container `migrate` schlägt fehl, Log `P1001`/`connect`/`timeout` | Datenbank nicht erreichbar (Foundation-Server, Firewall, TLS) | einmal `restart` (vorübergehender Ausfall); bleibt es, `needs_attention` an Strang A |
| `migrate` schlägt fehl mit Migrationsfehler (SQL, `P3009`) | Upstream-Migration fehlerhaft (Warnungen zu `pgcrypto` oder `vector` sind harmlos: beide Erweiterungen sind optional) | **Kein** `restart`-Kreislauf. `needs_attention`; nie Migrationen von Hand zurücksetzen |
| Server-Log `Redis`/`ECONNREFUSED ...:6379` | `affine-redis` nicht bereit | warten, bis `affine-redis` läuft, dann `restart`; fehlt `affine-redis`, `redeploy` |
| Pod `Pending` oder `ContainerCreating`, Event `Multi-Attach error` | ReadWriteOnce-Volume hängt noch am alten Pod oder Knoten | einige Minuten warten; `restart` hilft nicht. Bleibt es, `needs_attention` |
| `ImagePullBackOff` | Image-Digest im Sollzustand falsch oder Registry nicht erreichbar | `needs_attention` mit dem letzten Sollzustands-Commit |
| Smoke-Test `login`: „Smoke-Nutzer fehlt oder Passwort weicht ab“ | Nutzer `smoke@affine.invalid` fehlt oder Passwort wurde geändert | `needs_attention`; Abschnitt [Smoke-Nutzer](#smoke-nutzer) |
| Smoke-Test `document`: „Testdokument … nicht gefunden“ | **Datenverlust oder Datenbank-Wiederherstellung** | Sofort `needs_attention`. Kein `redeploy`, keine Wiederholungsschleife |
| Smoke-Test `attachment`: HTTP 404 | Anhang fehlt auf dem PVC (Volume ersetzt oder gelöscht) | Sofort `needs_attention`; Anhänge haben keine Sicherung |
| Smoke-Test `document-write`: `WebSocket`-Fehler | Ingress leitet WebSockets nicht weiter | `needs_attention` an Strang B (Ingress) |
| Hochladen größerer Dateien scheitert mit 413 | Body-Limit des Ingress-Controllers (Standard 1 MB) | kein Agentenfall; Strang B: Ingress-Annotation |

## Erlaubte Aktionen

- **`restart`**: `kubectl -n $NS rollout restart deployment/affine`. Wegen `Recreate` ist AFFiNE etwa eine Minute nicht erreichbar; die Migrationen laufen erneut und sind idempotent. Daten bleiben unberührt.
- **`redeploy`**: `app-deploy.yml` für `affine`/`<env>`. Erzwingt ein Helm-Upgrade auf den Sollzustand (setzt manuelle Abweichungen wie die Replica-Zahl zurück). Ändert nichts an Datenbank, PVC oder Secrets.

Danach jeweils Smoke-Test abwarten. Bleibt er nach `restart` und einem `redeploy` negativ, ist der Fall nicht autonom lösbar: `needs_attention` mit Befund und, falls vorhanden, dem auslösenden Commit.

## Grenzen

- Nicht mehr als 1 Replica: Anhänge liegen auf einem ReadWriteOnce-Volume (das Chart-Schema lässt höchstens 1 zu).
- Keine Änderungen an Datenbank `affine`, PVC `affine-data`, Secret `affine-platform`, Namespace oder Ingress. Nichts löschen.
- Keine Wiederherstellung, kein Zurückspielen von Migrationen, kein Versionswechsel. Versionen ändern sich nur über das Repository `hackathon-platform-affine` (siehe [Upgrade](#upgrade)).
- `values` im Sollzustand nicht autonom ändern; ein Revert eines fehlerhaften Commits ist eine menschliche Entscheidung.
- Nach Datenverlust-Befunden (`document`, `attachment`) keine weiteren Aktionen, um Spuren nicht zu überschreiben.

## Smoke-Nutzer

Der Smoke-Test meldet sich als `smoke@affine.invalid` an. Das Passwort sind die **ersten 32 Zeichen** von `SMOKE_USER_PASSWORD` im Secret `affine-platform` (AFFiNE erlaubt höchstens 32 Zeichen, der generierte Wert hat 40).

- **Frische Instanz**: Hat AFFiNE noch keinen Administrator, legt der erste Smoke-Lauf den Smoke-Nutzer über die Ersteinrichtung als ersten Administrator an, danach einen Arbeitsbereich „MMK Smoke“ mit dem Testdokument `mmk-smoke-persistence` und dem Anhang `mmk-smoke-attachment.txt`.
- **Erste menschliche Administration**: Mit den Smoke-Zugangsdaten unter `https://affine.<baseDomain>/admin` anmelden, persönliche Konten anlegen und ihnen Administratorrechte geben. Das Passwort des Smoke-Nutzers nicht ändern.
  ```bash
  kubectl -n affine-staging get secret affine-platform -o jsonpath='{.data.SMOKE_USER_PASSWORD}' | base64 -d | cut -c1-32
  ```
- **Instanz schon eingerichtet, Smoke-Nutzer fehlt**: Im Admin-Bereich das Konto `smoke@affine.invalid` mit diesem Passwort anlegen. Der nächste Smoke-Lauf legt den Arbeitsbereich an, sofern der Nutzer noch keinen hat.
- Der Arbeitsbereich „MMK Smoke“ gehört dem Test. Nicht löschen: Der Smoke-Test legt das Testdokument absichtlich **nicht** neu an, wenn der Nutzer Arbeitsbereiche hat und das Dokument fehlt, sondern meldet Datenverlust.

## Datenverfahren

| Verfahren | Vorgehen |
| --- | --- |
| Migration | Upstream-Migrationen laufen bei jedem Pod-Start im Init-Container `migrate`. Vor einem Versionswechsel Release Notes lesen; ein Zurück auf eine ältere Version nach erfolgten Migrationen ist nicht vorgesehen |
| Sicherung | Datenbank `affine` über die Sicherung des Foundation-PostgreSQL-Servers (7 Tage Point-in-Time-Restore, Strang A). Anhänge und `private.key` auf `affine-data` haben **keine** Sicherung (Staging-Risiko) |
| Wiederherstellung | Nur durch Menschen: Point-in-Time-Restore des Foundation-Servers auf einen neuen Server, Datenbank `affine` von dort mit `pg_dump`/`pg_restore` in die bestehende Datenbank übernehmen (Zeitpunkt vorher notieren, AFFiNE dafür auf 0 Replicas), danach `redeploy`. Anhänge sind nicht wiederherstellbar; geht `private.key` verloren, erzeugt `migrate` einen neuen, bestehende Freigabelinks und Sitzungen werden ungültig |

## Upgrade

1. Im Repository `hackathon-platform-affine` auf `main` `image` in `platform-delivery/environments/staging/affine.yaml` (Digest des neuen Upstream-Releases) und `appVersion` in `charts/affine/Chart.yaml` anheben.
2. `platform-package.yml` testet Chart, Migrationen und Smoke-Test in kind, einschließlich Persistenz und Fehlerwert.
3. Nur wenn beides grün ist, veröffentlicht der Workflow Chart und Smoke-Image und legt ein Release an. `app-affine-sync.yml` im Plattform-Repository übernimmt es innerhalb von 15 Minuten validiert auf `main` und startet `app-deploy.yml`.
4. Vorher den Zeitpunkt notieren (Ziel für einen Point-in-Time-Restore).

Lokal prüfen: `test/e2e-kind.sh --fault` (Docker, kind, kubectl, helm, Python mit PyYAML).

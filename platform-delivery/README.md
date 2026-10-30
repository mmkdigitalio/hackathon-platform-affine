# Lieferung an die MMK-Plattform

Antwort auf [`platform/operations/apps/affine/LIEFERANFORDERUNGEN.md`](https://github.com/mmkdigitalio/hackathon-platform-team/blob/main/platform/operations/apps/affine/LIEFERANFORDERUNGEN.md) in `mmkdigitalio/hackathon-platform-team`. Dieses Verzeichnis hat dieselbe Struktur wie `platform/` dort und lässt sich direkt prüfen:

```bash
# im Plattform-Repository, platform/schemas/app-catalog
npx tsx src/cli.ts validate --tree <pfad>/hackathon-platform-affine/platform-delivery
```

| Nr. | Lieferung | Wo |
| --- | --- | --- |
| L1 | Katalogeintrag | [`catalog/affine/app.yaml`](catalog/affine/app.yaml); Übergabe-PR durch [`platform-package.yml`](../.github/workflows/platform-package.yml) |
| L2 | Chart | [`charts/affine`](../charts/affine), veröffentlicht als `oci://ghcr.io/mmkdigitalio/charts/affine` Version `0.1.<Lauf>`; Image unverändert `ghcr.io/toeverything/affine` |
| L3 | Werte-Vertrag | `image.repository`/`image.digest`, `imagePullSecretName`, `secretName` per `envFrom`, `platform.persistentVolumeClaim`, `platform.replicas`, `platform.resources`, `platform.url`/`host`. Chart legt nur Deployment, Service und ConfigMap an |
| L4 | Deployment | `affine`, `Recreate`, Label `app.kubernetes.io/instance: affine`, Service `affine:3010` |
| L5 | Konfiguration | `values.affine.nodeOptions`, `values.affine.config` (in `config.json` gemischt); [`values.schema.json`](../charts/affine/values.schema.json) lässt `platform` und weitere Schlüssel zu. `rolloutMarker`/`platform.release` nicht in Pod-Templates |
| L6 | Verfügbarkeitspfad | `/info` (200 ohne Anmeldung) |
| L7 | Smoke-Test-Image | [`smoke/`](../smoke), `ghcr.io/mmkdigitalio/affine-smoke@sha256:…`; prüft Anmeldung, Dokument (lesen und schreiben) und Anhang |
| L8 | Persistenznachweis | Testdokument `mmk-smoke-persistence` mit Anhang `mmk-smoke-attachment.txt` im Arbeitsbereich „MMK Smoke“; `evidence` nennt `workspace/<id>/doc/…` und `workspace/<id>/blob/…` |
| L9 | Runbook | [`runbook/README.md`](../runbook/README.md); `runbook.commit` setzt der Übergabe-PR |
| L10 | Datenverfahren | `dataProcedures` im Katalogeintrag |
| L11 | Fehlerwert | [`fault-invalid-config.yaml`](fault-invalid-config.yaml): `affine.nodeOptions = --max-old-space-size=16` |
| L12 | Smoke-Image-Herkunft | öffentlich von `ghcr.io` (kein `acr:`) |

[`environments/staging/affine.yaml`](environments/staging/affine.yaml) ist ein Vorschlag für den Sollzustand, den Strang B anlegt.

## Abhängigkeiten auf Plattformseite

- **`pgcrypto`**: AFFiNEs Migrationen führen `CREATE EXTENSION pgcrypto` als Login `affine` aus. Auf Azure Flexible Server muss `azure.extensions` des Foundation-Servers `PGCRYPTO` enthalten (Strang A). `vector` ist optional; ohne die Erweiterung überspringen die Migrationen die KI-Tabellen.
- **Ingress**: WebSockets müssen durchgereicht werden (Dokumentänderungen laufen über Socket.IO). Für Anhänge über 1 MB braucht die Ingress-Regel ein höheres Body-Limit (Strang B).
- **GHCR-Sichtbarkeit**: Chart- und Smoke-Paket nach dem ersten Veröffentlichen einmalig auf „public“ stellen (Organisations-Admin), sonst kann der Cluster sie nicht ziehen.
- **Übergabe-Token**: Repository-Secret `PLATFORM_REPO_TOKEN` (Schreibrechte auf Inhalte und Pull Requests im Plattform-Repository); ohne es endet `platform-package.yml` mit der Zusammenfassung zum manuellen Übernehmen.

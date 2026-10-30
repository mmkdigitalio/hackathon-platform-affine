# Lieferung an die MMK-Plattform

Antwort auf [`platform/operations/apps/affine/LIEFERANFORDERUNGEN.md`](https://github.com/mmkdigitalio/hackathon-platform-team/blob/main/platform/operations/apps/affine/LIEFERANFORDERUNGEN.md) in `mmkdigitalio/hackathon-platform-team`. Dieses Verzeichnis hat dieselbe Struktur wie `platform/` dort und lässt sich direkt prüfen:

```bash
# im Plattform-Repository, platform/schemas/app-catalog
npx tsx src/cli.ts validate --tree <pfad>/hackathon-platform-affine/platform-delivery
```

| Nr. | Lieferung | Wo |
| --- | --- | --- |
| L1 | Katalogeintrag | [`catalog/affine/app.yaml`](catalog/affine/app.yaml); [`platform-package.yml`](../.github/workflows/platform-package.yml) testet ihn; den neuesten grünen Lauf auf `main` übernimmt `app-affine-sync.yml` im Plattform-Repository |
| L2 | Chart | [`charts/affine`](../charts/affine), in der Foundation-ACR als `oci://<acr>/helm/affine` (Katalog `acr: helm/affine`), Version `0.1.<Lauf>`; Image unverändert `ghcr.io/toeverything/affine` |
| L3 | Werte-Vertrag | `image.repository`/`image.digest`, `imagePullSecretName`, `secretName` per `envFrom`, `platform.persistentVolumeClaim`, `platform.replicas`, `platform.resources`, `platform.url`/`host`. Chart legt nur Deployment, Service und ConfigMap an |
| L4 | Deployment | `affine`, `Recreate`, Label `app.kubernetes.io/instance: affine`, Service `affine:3010` |
| L5 | Konfiguration | `values.affine.nodeOptions`, `values.affine.config` (in `config.json` gemischt); [`values.schema.json`](../charts/affine/values.schema.json) lässt `platform` und weitere Schlüssel zu. `rolloutMarker`/`platform.release` nicht in Pod-Templates |
| L6 | Verfügbarkeitspfad | `/info` (200 ohne Anmeldung) |
| L7 | Smoke-Test-Image | [`smoke/`](../smoke), `acr:affine-smoke@sha256:…`; prüft Anmeldung, Dokument (lesen und schreiben) und Anhang |
| L8 | Persistenznachweis | Testdokument `mmk-smoke-persistence` mit Anhang `mmk-smoke-attachment.txt` im Arbeitsbereich „MMK Smoke“; `evidence` nennt `workspace/<id>/doc/…` und `workspace/<id>/blob/…` |
| L9 | Runbook | [`runbook/README.md`](../runbook/README.md); `runbook.commit` ist der Commit des übernommenen grünen Laufs |
| L10 | Datenverfahren | `dataProcedures` im Katalogeintrag |
| L11 | Fehlerwert | [`fault-invalid-config.yaml`](fault-invalid-config.yaml): `affine.nodeOptions = --max-old-space-size=16` |
| L12 | Smoke-Image-Herkunft | Foundation-ACR (`acr:`); GHCR-Pakete der Organisation dürfen nicht öffentlich sein |

[`environments/staging/affine.yaml`](environments/staging/affine.yaml) ist ein Vorschlag für den Sollzustand, den Strang B anlegt.

## Abhängigkeiten auf Plattformseite

- **PostgreSQL-Erweiterungen: keine nötig.** AFFiNE 0.27.4 versucht `pgcrypto` und `vector` anzulegen, fängt Fehler aber ab (nur `WARNING`). Ohne Erweiterungen laufen Migrationen, Server und Smoke-Test vollständig durch (geprüft mit einem Login ohne `CREATE`-Recht auf der Datenbank). `pgcrypto` hasht nur bereits vorhandene Zugriffstoken; `vector` dient nur den KI-Funktionen.
- **Ingress**: WebSockets müssen durchgereicht werden (Dokumentänderungen laufen über Socket.IO). Für Anhänge über 1 MB braucht die Ingress-Regel ein höheres Body-Limit (Strang B).
- **Übergabe ohne Token**: `platform-package.yml` legt nach grünem Test ein Release `package-<Version>` mit `platform-release.json` an (Quell-Commit, Chart-Version, Smoke-Image). `app-affine-sync.yml` im Plattform-Repository liest es alle 15 Minuten (oder per `workflow_dispatch`), committet Katalog und Sollzustand validiert auf `main` und startet `app-deploy.yml`.

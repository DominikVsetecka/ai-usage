# AI Usage Claude Context

## Orbit lesen

Vor neuer Arbeit bitte zuerst:

1. `_orbit/data/projects/ai-usage.json` lesen
2. die verknuepften offenen Orbit-Tickets lesen
3. danach `PROGRESS.md`, `ROADMAP.md` oder `PLAN.md` nur noch zur Vertiefung nutzen

Orbit ist die kanonische Quelle fuer den aktuellen operativen Zustand.

Relevante operative Arbeit sollte in Orbit sichtbar sein. Nicht jeder Mikro-Schritt braucht sofort ein eigenes Ticket, aber mehrschrittige oder spaeter wiederaufnehmbare Arbeit sollte ueber ein Orbit-Ticket abgebildet sein.

Merke fuer neue Eintraege:

- offene oder mehrschrittige Arbeit -> Ticket
- Richtungs- oder Architekturentscheidung -> Decision
- wiederverwendbarer Fix, Pattern oder Ablauf -> KB
- reine Chronologie oder Repo-Kontext -> `PROGRESS.md`, `ROADMAP.md`, `PLAN.md`

Commits sollten bevorzugt nach sauberen Teilbloecken erfolgen, nicht nach jedem Mikro-Schritt. Vor Projektwechseln oder Session-Uebergaben ist ein sauberer Commit-Stand sinnvoll.

Wichtig:

- `PROGRESS.md`, `ROADMAP.md` und `PLAN.md` bleiben die projektlokale Langform im Repo
- diese Dateien sollen committed und gepusht werden
- Orbit fuehrt nur die verdichtete operative Sicht und keine vollstaendige Spiegelung dieser Texte
- falls vorhanden, enthaelt `_orbit/data/knowledge/` nur wiederverwendbare Fixes, Patterns und Runbooks
- die Langform-Dateien sollten oben einen kleinen `Orbit refs`-Block mit Projekt-ID sowie relevanten `ORB-...`- und `DEC-...`-Verweisen tragen
- neue oder manuell angelegte Orbit-Tickets muessen immer ein `created_at` im ISO-Format mit Zeitzone enthalten
- Uhrzeiten fuer `created_at`, Kommentar-`created_at` oder Event-`ts` niemals raten, sondern immer per `date +"%Y-%m-%dT%H:%M:%S%z"` holen

## Projektkontext

AI Usage ist ein privates macOS-Menubar-Tool. Es soll kompakt ein bis drei Prozentwerte in der oberen macOS-Menueleiste zeigen:

```text
C1 43%  C2 71%  GPT 12%
```

Geplante Quellen:

- Claude Subscription 1
- Claude Subscription 2
- GPT Codex

Leitplanken:

- Swift native macOS app.
- Sehr reduzierter Scope, inspiriert von ClaudeBar, aber kein Clone.
- 30 Sekunden Default-Refresh, spaeter einstellbar.
- Aktuell CLI-first; geplanter Claude-Profilmodus importiert OAuth-Credentials ausschliesslich in app-eigene Keychain-Eintraege (`ORB-0120`, `DEC-0005`).
- Keine Browser-Cookies und kein Full Disk Access im MVP.
- Keine Telemetrie.
- Keine Shell-String-Ausfuehrung.

Vor echtem Probe-Code:

1. lokale `claude` und `codex` Befehle / Usage-Ausgaben pruefen
2. Fixture-Ausgaben speichern
3. Parser-Tests schreiben
4. erst danach echte Probes aktivieren

Aktuelle relevante Dateien:

- `PLAN.md`
- `ROADMAP.md`
- `PROGRESS.md`
- `Package.swift`
- `Sources/AIUsageCore/`
- `Sources/AIUsage/`
- `Sources/AIUsageChecks/`
- `config.example.json`
- `../_orbit/data/projects/ai-usage.json`
- `../_orbit/data/tickets/ORB-0120.json`
- `../_orbit/data/tickets/ORB-0121.json`
- `../_orbit/data/tickets/ORB-0122.json`
- `../_orbit/data/decisions/DEC-0005.json`

Aktuelle Kommandos:

- `swift build`
- `swift run AIUsage`
- `swift run AIUsageChecks`

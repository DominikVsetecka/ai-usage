# AI Usage Agent Notes

## Orbit

Vor groesseren Implementierungs-, Review- oder Planungsaufgaben zuerst in Orbit nachsehen:

1. `../_orbit/data/projects/ai-usage.json` lesen
2. offene Orbit-Tickets fuer dieses Projekt pruefen
3. erst danach `PROGRESS.md`, `ROADMAP.md` oder `PLAN.md` zur Vertiefung lesen

Orbit ist die operative Quelle fuer:

- aktuellen Status
- naechste sinnvolle Arbeit
- offene Entscheidungen

Weiche Arbeitsregel:

- relevante, mehrschrittige oder spaeter wiederaufnehmbare Arbeit sollte in Orbit sichtbar sein
- nicht jeder Mikro-Schritt braucht ein eigenes Ticket
- wenn noch kein passendes Ticket existiert und die Arbeit ueber einen kleinen Einzelschritt hinausgeht, sollte zuerst oder frueh ein Orbit-Ticket angelegt werden

Eintragstypen in Orbit:

- operative offene Arbeit -> Ticket
- Richtungs- oder Architekturentscheidung -> Decision
- wiederverwendbarer Fix, Pattern oder Ablauf -> KB als `incident`, `pattern` oder `runbook`
- reine Chronologie oder Repo-Kontext -> `PROGRESS.md`, `ROADMAP.md`, `PLAN.md`

Commit-Regel:

- nach abgeschlossenen, sauberen Teilbloecken moeglichst committen
- nicht nach jedem Mikro-Schritt committen
- vor Projektwechseln oder Session-Uebergaben nach Moeglichkeit einen sauberen Commit-Stand herstellen

Projekt-Dokumente bleiben wichtig:

- `PROGRESS.md`, `ROADMAP.md` und `PLAN.md` leben im Projektordner
- sie werden mit dem Projekt committed und gepusht
- Orbit fuehrt diese Inhalte nicht als volle Duplikate
- sie sollten oben einen kleinen `Orbit refs`-Block mit Projekt-ID sowie relevanten `ORB-...`- und `DEC-...`-Verweisen tragen

Orbit hat Prioritaet fuer den aktuellen operativen Arbeitszustand.

Wenn ein neues Orbit-Ticket manuell als JSON angelegt oder editiert wird:

- immer `created_at` mit ISO-Zeitstempel und Zeitzone setzen
- Beispiel: `2026-05-24T11:20:00+02:00`
- Uhrzeiten niemals raten, sondern vorher per `date +"%Y-%m-%dT%H:%M:%S%z"` abfragen
- dieselbe Regel gilt fuer Projekt-`created_at`, Kommentar-`created_at` und Event-`ts`
- diesen Wert nur bei der erstmaligen Anlage setzen, spaeter nicht ueberschreiben

## Nach groesseren Schritten

Nach einer abgeschlossenen Teilaufgabe:

1. projektlokale Doku aktualisieren, wenn Implementierungslog oder Richtung betroffen sind
2. passendes Orbit-Ticket aktualisieren
3. Kommentar oder Statuswechsel hinterlegen
4. bei Richtungswechseln eine Entscheidung in `_orbit/data/decisions/` anlegen oder aktualisieren
5. nur wenn die Erkenntnis spaeter wiederverwendbar ist: KB-Eintrag in `_orbit/data/knowledge/` anlegen

Nicht tun:

- dieselbe Langform-Roadmap oder denselben Progress komplett in Orbit nachschreiben
- aus jedem kleinen Einmal-Fix einen KB-Eintrag machen

## Projekt-Setup

Projektkontext:

- Projekt-ID: `ai-usage`
- Pfad: aktueller Projektordner
- Ziel: reduzierte macOS Swift menu bar app fuer AI-Usage-Prozentwerte
- Default Refresh: 30 Sekunden, konfigurierbar
- Quellen: Claude Subscription 1, Claude Subscription 2, GPT Codex
- Sicherheitslinie: aktuell CLI-first; geplanter Profilmodus nur mit getrennten app-eigenen Keychain-Eintraegen, nie Browser-Cookies oder Full Disk Access (`ORB-0120`, `DEC-0005`)

Vor Implementierung die konkrete lokale CLI-Ausgabe fuer `claude` und `codex` pruefen, bevor Parser gebaut werden.

Build-/Run-Kommandos werden nach dem Swift-Scaffold ergaenzt.

Aktuelle Kommandos:

- Build: `swift build`
- App starten: `swift run AIUsage`
- Checks: `swift run AIUsageChecks`

Hinweis: In der aktuellen CommandLineTools-Umgebung sind `XCTest` und Swift `Testing` nicht verfuegbar. Deshalb nutzt das Projekt vorerst `AIUsageChecks` als assertion-basierten Check-Runner.

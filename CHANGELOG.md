# Story Recall – Änderungen

## 0.9.9 (Nov. 2026)

**Neu**
- **Reihen-Lexikon:** Das Story-Lexikon eines späteren Bandes führt die Einträge der früheren Bände weiter, als wäre die Reihe ein langes Buch. Fakten sammeln sich an, Zustand und Beziehung kommen vom neuesten Stand, jeder Eintrag zeigt, in welchem Band er zuerst und zuletzt vorkam („Band 1 · …“). Als „beendet“ markierte frühere Bände zählen ganz.
- **Story Recall bei Comics** (Bildseiten, siehe README).
- **WLAN halten, solange die KI arbeitet** und am Ladekabel auch in den Wartepausen und beim Warten auf das Tageslimit wach bleiben. Danach schläft das Gerät wieder normal.

**Verbessert**
- **Längere Pausen bei Überlastung** des Anbieters: 2, 4, 8 Minuten, danach je 8 Minuten.
- **Ersatzmodell mit Ruhezeit:** Nach einem Wechsel bleibt Story Recall 15 Minuten beim Ersatzmodell (nach einem Tageslimit eine Stunde), statt es bei jedem Paket erneut am überlasteten Hauptmodell zu versuchen. Das spart vergebliche Anfragen am kostenlosen Tageslimit.
- Zeitüberschreitung bei Anfragen: 4 Minuten auf die erste Antwort, 5 Minuten insgesamt.

## Nach 0.9.8 (24.–25.10.2026, noch ohne neue Versionsnummer)

**Neu**
- **Bei Überlastung: warten oder anderes Modell** (KI-Einstellungen). Standard ist „warten“: Story Recall bleibt beim gewählten Modell und versucht es nach einer Pause weiter, so stammen alle Notizen eines Buchs vom selben Modell. Mit „anderes Modell“ wechselt es erst nach drei Fehlversuchen hintereinander (oder sofort beim Tageslimit).
- **Anleitung, Seiten „Kosten (grob)“ und „Spartipps“:** ungefähre Kosten für kurze, mittlere und lange Bücher mit Claude Haiku, Claude Sonnet und Gemini, dazu vier Tipps mit Menüweg.
- Hinweis bei „Ganzes Buch beim Öffnen verarbeiten“, dass es trotzdem spoilerfrei bleibt.
- Sind alle Kapitel fertig, steht in der Statuszeile „tippen zum Neuerstellen“.
- **Frühere KI-Notizen:** „Alle KI-Notizen neu erstellen“ hebt den bisherigen Stand auf, bis zu zwei pro Anbieter. Unter Buch & Notizen → „Frühere KI-Notizen“ wechselst du ohne neue Anfragen zurück, z. B. von Claude wieder zu Gemini oder zum vorherigen Modell, oder löschst einen Stand einzeln. Eigene Notizen und Lesestelle bleiben dabei unberührt.
- **Anleitung, zweite Seite „Gut zu wissen“:** Geschichte bisher neu schreiben, Statuszeile, KI-Notizen verbessern, spoilerfrei.
- **Live-Fortschritt:** Ist das Story-Recall-Menü offen, aktualisiert sich „KI-Notizen: x/y“ nach jedem fertigen Paket und bei jedem Statuswechsel von selbst.

**Verbessert**
- **Prompt für die Kapitel-Notizen** überarbeitet (nach einem Vergleich mit X-Ray, KO Catchup und Reading Companion): Lässt das Buch etwas offen, notiert die KI es als offen, statt es aufzulösen; ein unsicheres Detail lässt sie weg. Neutrale Beispiele, Regeln für die Lexikon-Einträge als kurze Liste.
- Die Statuszeile unterscheidet „Pause: überlastet“ und „Pause: Antwort unbrauchbar“.

**Behoben**
- Claude schrieb manchmal statt einer Zusammenfassung nur einen Platzhalter („x“) oder ließ sie leer. Solche Antworten werden nicht mehr gespeichert, schon gespeicherte Platzhalter beim Öffnen des Buchs entfernt und neu angefragt.
- Reste der Antwortform am Textende (z. B. „}, {“) werden entfernt, auch in schon gespeicherten Notizen.

## 0.9.8 (24.10.2026)

**Neu**
- **Story-Lexikon:** Suche über alle Kategorien. Findet die Suche nichts, kann die KI nachsehen (nur in den schon gelesenen Kapiteln). Sortierung umschaltbar: A–Z, Häufigkeit, zuletzt gesehen. Kleine Kategorien (unter 3 Einträgen) landen unter „Sonstiges“, Figuren und Orte bleiben immer. Figuren zeigen ihren aktuellen Stand (z. B. verschwunden, verbündet).
- **Geschichte bisher neu schreiben:** im Hauptmenü und im ☰ des Rückblicks, als eigene Anfrage aus allen Kapitel-Zusammenfassungen.
- **Reihen-Rückblick:** Die Zusammenfassung eines fertig gelesenen Bandes wird in einer eigenen Anfrage geschrieben (drei Absätze: Handlung, Figuren, Stand am Ende). Im ☰ des Reihen-Rückblicks lässt sie sich neu schreiben.
- **Vorher fragen:** Nach einer Pause und beim Start eines neuen Bandes fragt Story Recall auf Wunsch zuerst, ob du den Rückblick sehen möchtest.
- **Hinweis, wenn die KI-Notizen stoppen:** einmal pro Vorfall ein Fenster bei abgelehntem oder abgelaufenem Schlüssel und bei fehlendem Guthaben, mit Knopf zu den KI-Einstellungen.
- **Statuszeile „KI-Notizen: x/y“:** Sind alle Kapitel fertig, bietet Antippen an, alle Notizen neu zu erstellen. Nach einem neuen Schlüssel ebenso.
- **Wie funktioniert das?** als letzter Eintrag unter Einstellungen.

**Verbessert**
- Menü neu geordnet, jedes Menü passt auf eine Bildschirmseite. Story Recall steht oben im Werkzeuge-Menü.
- KI-Notizen automatisch wählbar: bei WLAN, nur beim Aufladen oder nur auf Wunsch. Lesezeit zählt nur bei echtem Lesen.
- Wartezeiten und Tageslimits werden bei allen Anbietern erkannt, die Arbeit geht danach von selbst weiter.
- Anfragen laufen im Hintergrund, KOReader bleibt bedienbar.

**Behoben**
- Mit Claude scheiterte „Geschichte bisher neu schreiben“ an der Antwort-Vorlage (fehlendes `additionalProperties: false`).
- Die Lexikon-Sortierung „Häufigkeit“ wirkte nicht.

## 0.9.5 (22.10.2026)

- Behoben: Das Story-Lexikon schloss die Liste beim Antippen eines Eintrags.
- Neue Tests für das Lexikon.

## 0.9.4 (22.10.2026)

- Rückblick als Hauptfenster mit den Knöpfen Chronik, Story-Lexikon, + Notiz und Weiterlesen.
- Story-Lexikon mit Kategorien, doppelte Einträge zusammengefasst.
- Behoben: leere letzte Chronik-Seite, Rückblick bei fertig gelesenen Büchern, Textstellen bei fertig gelesenen Büchern.

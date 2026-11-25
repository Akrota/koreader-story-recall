# Changelog – Story Recall

*Deutsche Fassung weiter unten.*

## 0.9.9 (Nov 2026)

**New**
- **Series lexicon:** the story lexicon of a later volume carries on the entries of the earlier volumes, as if the series were one long book. Facts add up, status and relation come from the newest state, and every entry shows in which volume it first and last appeared ("Vol. 1 · …"). Earlier volumes marked as "finished" count in full.
- **Story Recall for comics** (image pages, see README).
- **Wi-Fi stays on while the AI is working**, and while plugged in the device also stays awake during pauses and while waiting for the daily limit. Afterwards it sleeps normally again.

**Improved**
- **Longer pauses when the provider is overloaded:** 2, 4, 8 minutes, then 8 minutes each.
- **Resting time for the fallback model:** after switching, Story Recall stays on the fallback model for 15 minutes (one hour after a daily limit) instead of trying the overloaded main model again for every batch. This saves wasted requests of the free daily limit.
- Request timeout: 4 minutes for the first response, 5 minutes in total.

## After 0.9.8 (24–25 Oct 2026, no new version number)

**New**
- **When overloaded: wait or use another model** (AI settings). The default is "wait": Story Recall stays with the chosen model and tries again after a pause, so all notes of a book come from the same model. With "other model" it only switches after three failures in a row (or at once on a daily limit).
- **Guide, pages "Costs (roughly)" and "Saving tips":** approximate costs for short, medium and long books with Claude Haiku, Claude Sonnet and Gemini, plus four tips with the menu path.
- A note on "Process the whole book when opening" that it stays spoiler-free anyway.
- When all chapters are done, the status line says "tap to recreate".
- **Earlier AI notes:** "Recreate all AI notes" keeps the previous state, up to two per provider. Under Book & notes → "Earlier AI notes" you can switch back without new requests, or delete one. Your own notes and reading position are not touched.
- **Guide, second page "Good to know":** rewrite the story so far, status line, improving AI notes, spoiler-free.
- **Live progress:** with the Story Recall menu open, "AI notes: x/y" updates itself after every finished batch and every status change.

**Improved**
- **Prompt for the chapter notes** reworked (after comparing with X-Ray, KO Catchup and Reading Companion): if the book leaves something open, the AI notes it as open instead of resolving it; uncertain details are left out. Neutral examples, the rules for lexicon entries as a short list.
- The status line tells "Pause: overloaded" and "Pause: answer unusable" apart.

**Fixed**
- Claude sometimes wrote only a placeholder ("x") instead of a summary, or left it empty. Such answers are no longer saved; saved placeholders are removed when the book is opened and requested again.
- Leftovers of the answer format at the end of texts (for example "}, {") are removed, also from saved notes.

## 0.9.8 (24 Oct 2026)

**New**
- **Story lexicon:** search across all categories. If the search finds nothing, the AI can look it up (only in the chapters already read). Sorting can be switched: A–Z, frequency, last seen. Small categories (under 3 entries) are grouped under "Other", characters and places always stay. Characters show their current status (for example missing, allied).
- **Rewrite the story so far:** in the main menu and in the ☰ of the recap, as its own request from all chapter summaries.
- **Series recap:** the summary of a finished volume is written in its own request (three paragraphs: plot, characters, state at the end). It can be rewritten from the ☰ of the series recap.
- **Ask first:** after a break and when starting a new volume, Story Recall can ask whether you want to see the recap.
- **Note when the AI notes stop:** one window per incident for a rejected or expired key and missing credit, with a button to the AI settings.
- **Status line "AI notes: x/y":** when all chapters are done, tapping offers to recreate all notes. Likewise after a new key.
- **How does it work?** as the last entry under Settings.

**Improved**
- Menu reorganised, every menu fits on one screen. Story Recall is at the top of the Tools menu.
- Automatic AI notes can be chosen: with Wi-Fi, only while charging, or only on request. Reading time only counts when you really read.
- Waiting times and daily limits are recognised for all providers, work continues by itself afterwards.
- Requests run in the background, KOReader stays usable.

**Fixed**
- With Claude, "Rewrite the story so far" failed because of the answer template.
- The lexicon sorting "frequency" had no effect.

## 0.9.5 (22 Oct 2026)

- Fixed: the story lexicon closed the list when tapping an entry.
- New tests for the lexicon.

## 0.9.4 (22 Oct 2026)

- Recap as the main window with the buttons Chronicle, Story lexicon, + Note and Continue reading.
- Story lexicon with categories, duplicate entries merged.
- Fixed: empty last page of the chronicle, recap for finished books, text passages for finished books.

---

# Deutsch

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

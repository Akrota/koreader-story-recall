# Story Recall

*English below.*

Ein KOReader-Plugin, das dich spoilerfrei an die bisherige Geschichte erinnert, genau bis zu deiner Stelle im Buch.

## Was es kann

- **Rückblick nach einer Pause:** Öffnest du ein Buch nach einigen Tagen wieder, siehst du, was bisher geschah und wo die Geschichte gerade steht.
- **Story-Chronik:** Alle gelesenen Kapitel mit kurzer Zusammenfassung und deinen eigenen Notizen. Mit Sprung zur ersten oder letzten Seite. Lange auf die Seitenzahl tippen springt zu einem Kapitel.
- **Reihen-Rückblick:** Beim Start eines neuen Bandes erfährst du, was in den vorherigen Bänden passiert ist.
  - Die Zusammenfassung jedes Bandes wird zusätzlich in einem Reihen-Archiv gesichert, gelöschte Bücher bleiben also im Rückblick.
  - Hast du einen Band woanders gelesen, zum Beispiel auf Papier, gibt es „Schon woanders gelesen“.
  - Hast du die früheren Bände gar nicht digital, kann die KI sie aus dem Internet zusammenfassen. Das geht mit Gemini, Claude, OpenAI und OpenRouter, ist deutlich gekennzeichnet und zeigt die Quellen.
  - Übersetzungen mit anderem Reihennamen werden einmal nachgefragt und danach verknüpft.
- **Wer war das noch mal?** Einen Namen markieren und „Story-Kontext“ antippen. Du siehst, wer das ist, die Beziehung zur Hauptfigur und alles Bisherige, auf Wunsch auch die Textstellen. Das Story-Lexikon zeigt alles auf einen Blick, sortiert nach Figuren, Orten, Gegenständen, Gruppen und Sonstigem.
- **Eigene Notizen** zu jedem Kapitel.
- **KI-Notizen korrigieren:** Du kannst Zusammenfassungen von Hand verbessern, das Original bleibt erhalten.
- **Export** als Markdown-Datei neben dem Buch.
- **ZenOS:** Home-Widget, Aktionen für Controls, Navbar und Launcher, Knopf im Markieren-Menü. Funktioniert auch ohne ZenOS.
- **Sprache der Notizen:** Standardmäßig in der Sprache von KOReader, auch bei englischen Büchern. Alternativ in der Sprache des Buches.

Nichts zeigt mehr als das, was du gelesen hast. Wer im Inhaltsverzeichnis vorspringt, schaltet dadurch nichts frei.

## KI und Datenschutz

Die Kapitel-Notizen erstellt eine KI deiner Wahl: Google Gemini (mit kostenlosem Kontingent), Claude, OpenAI, OpenRouter, Mistral, DeepSeek oder ein eigener OpenAI-kompatibler Dienst. Jedes Kapitel wird **einmal** verschickt. Danach funktioniert alles offline auf dem E-Reader, ein Heimcomputer ist nicht nötig. Der API-Schlüssel bleibt auf dem Gerät und geht nur an den gewählten Anbieter. Beim kostenlosen Gemini-Zugang darf Google die Texte zum Training verwenden. Getestet sind bisher nur Gemini und Claude mit echten Anfragen; die anderen Anbieter sind nach ihrer Dokumentation eingebaut, aber noch nicht echt getestet.

Wissen über Figuren wird nur ergänzt, nie gekürzt oder überschrieben.

## Installation

1. Den Ordner `storyrecall.koplugin` in den `plugins`-Ordner von KOReader kopieren (Kobo: `.adds/koreader/plugins`).
2. KOReader neu starten und ein Buch öffnen. Eine kurze Anleitung erscheint.
3. **Werkzeuge → Story Recall → Einstellungen → KI → API-Schlüssel einrichten:** Den QR-Code mit dem Handy scannen und den Schlüssel einfügen.
4. „Jetzt starten“ antippen. Standardmäßig arbeitet das Plugin danach von selbst weiter, wenn das Gerät am Ladekabel hängt.

## Bedienung

- Menü: **Werkzeuge → Story Recall**
- Gesten: Einstellungen → Tippen und Gesten → Gestenverwaltung → Leseansicht → Story-Recall-Aktion.
- ZenOS: Damit „Story-Kontext“ im Markieren-Menü erscheint, unter Zen Settings → Lesemodus → Hervorheben / Nachschlagen → „Andere Elemente anzeigen“ einschalten. Das Widget gibt es unter Zen Settings → Home → Widgets → Story Recall.

Die Daten jedes Buches liegen in `story_recall.lua` im Metadaten-Ordner des Buches (`.sdr`), wandern also mit dem Buch mit.

---

# Story Recall (English)

A KOReader plugin that reminds you of the story so far, spoiler-free, exactly up to where you are in the book.

**Features:**
- a recap after a break
- a story chronicle with jump to chapter
- a series recap when you start the next volume (with a series archive, "already read elsewhere", an optional summary from the internet, and linking of translations)
- notes in KOReader's language or the book's
- "Who was that again?" (select a name → Story context)
- story lexicon (characters, places, objects, groups, other)
- your own notes
- correcting AI notes
- Markdown export
- ZenOS integration (Home widget, actions, highlight menu), and it works without ZenOS too

**AI:** pick Gemini (free tier), Claude, OpenAI, OpenRouter, Mistral, DeepSeek or any OpenAI-compatible service. Each chapter is sent once; afterwards everything works offline on the e-reader. The API key stays on the device. Only Gemini has been tested with real requests so far; the other providers follow their documentation but are not yet tested for real. Facts about characters are only ever added, never shortened or overwritten.

**Install:**
1. Copy `storyrecall.koplugin` into KOReader's `plugins` folder.
2. Restart KOReader and open a book.
3. Tools → Story Recall → Settings → AI → Set up API key (scan the QR code with your phone).
4. Tap "Start now".

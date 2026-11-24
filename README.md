# Story Recall for KOReader

*Deutsch: [README.de.md](README.de.md)*

A KOReader plugin that reminds you of the story so far, spoiler-free and exactly up to where you are in the book.

> **Status: beta (0.9.9).** All automated tests pass on Linux. Tested on a Kobo with real Gemini and Claude requests. The other AI providers have not been tried with real requests yet.

## Features

- **A recap after a break:** if you reopen a book after a few days, you see what has happened so far and where the story stands.
- **Story chronicle:** every chapter you've read, with a short summary and your own notes, plus a jump to each chapter.
- **Series recap:** when you start a new volume, you learn what happened in the previous ones.
  - Each volume's summary is also kept in a series archive, so deleted books stay in the recap.
  - If you read a volume elsewhere, for example on paper, you can mark it as "already read elsewhere".
  - If you don't have the earlier volumes digitally at all, the AI can summarise them from the internet. This is clearly marked and the sources are shown.
  - Translations with a different series name are asked about once and linked from then on.
  - The summary of a finished volume is written in its own request (plot, characters, where things stand). It can be written again from the series recap's ☰ menu.
- **Who was that again?** Select a name and tap "Story context". You see who it is, how they relate to the main character and everything known so far, and the text passages if you want. The **story lexicon** lists all characters, places, objects and groups by category. Search across all categories (if nothing is found, the AI can look it up in the chapters you have read), sort A–Z, by frequency or by last appearance.
- **Rewrite the story so far:** a fresh overview from all chapter summaries, one request.
- **Your own notes** on every chapter.
- **Correcting AI notes:** you can improve summaries by hand, and the original is kept.
- **Earlier AI notes:** if you create the AI notes again (for example with another provider), the old set is kept, up to two per provider. You can switch back without new requests.
- **Export** as a Markdown file next to the book.
- **ZenOS integration:** a Home widget, actions for controls, navbar and launcher, and a button in the highlight menu. The plugin works without ZenOS too.
- **Language of the notes:** KOReader's language by default, even for English books. The book's language is an alternative.

Nothing ever shows more than what you've read. Jumping ahead in the table of contents doesn't unlock anything.

## AI and privacy

The chapter notes are written by an AI of your choice:
- Google Gemini (with a free tier)
- Claude
- OpenAI
- OpenRouter
- Mistral
- DeepSeek
- any OpenAI-compatible service

**Only Google Gemini and Claude have been tested with real requests so far.** The other providers are built from their documentation but not yet tested with real requests. Feedback is welcome.

Each chapter is sent **once**. After that, everything works offline on the e-reader, and no home computer is needed. The API key stays on the device and only goes to the provider you chose. With the free Gemini tier, Google may use the texts for training.

Facts about characters are only ever added, never shortened or overwritten.

If the provider is overloaded, the plugin waits by default and tries again later with the same model. If you like, it switches to another model after three failed attempts. A rough cost estimate per book and saving tips are in the guide (Settings → How does it work?).

## Installation

1. Download the ZIP from [Releases](../../releases) and unpack it, or download this repository.
2. Copy the folder **`storyrecall.koplugin`** to KOReader's `plugins` folder. On a Kobo, that is `.adds/koreader/plugins/`.
3. Restart KOReader and open a book. A short guide appears.
4. Go to **Tools → Story Recall → Settings → AI → Set up API key**, scan the QR code with your phone and paste the key.
5. Tap "Start now". By default, the plugin then keeps working on its own while the device is charging.

More details on usage are in [`storyrecall.koplugin/README.md`](storyrecall.koplugin/README.md).

## Tests

`tests/` contains KOReader test patches (`2-storyrecall-*.lua`), unit tests that run without KOReader (`unit_*.lua`) and scripts to generate the test books. `testbooks/` holds two generated, copyright-free books. For each test, copy **one** patch to KOReader's `patches/` folder. `tests/run_tests_mac.sh` shows the full sequence.

## Who made this

The code was written entirely by **Claude**, an AI by Anthropic (in Claude Code on a Mac, with a code review and tests by a second Claude on Windows/Linux). The owner of this repository came up with the idea, tested the plugin and gave feedback, but did not write the code.

There is no warranty and no guaranteed support. Bug reports are welcome as [issues](../../issues). Please attach `crash.log` from the KOReader folder, and make sure it contains no API keys.

## Acknowledgements

How the AI providers are connected was inspired by the [X-Ray](https://github.com/ultimatejimmy/xray.koplugin) plugin for KOReader.

## License

[MIT](LICENSE)

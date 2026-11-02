# Reading speed (WPM) for KOReader

A KOReader plugin that measures your reading speed in words per minute.

KOReader's built-in Reading statistics track time and pages, but not words per minute. This plugin times the pages you actually read and ignores skimming, flipping, idle time, sleep, menus and navigation, so the number reflects real reading.

## Features

- **Show reading speed** (Tools → Reading speed (WPM)): your speed over the last 20 pages, this session, this book and all books, plus the estimated time left in the book at your speed.
- **Status bar**: recent WPM in the footer (can be turned off).
- **Settings** for the plausibility limits, sleep handling and detours (see below).
- **Reset** this book's stats or all books' stats.
- **Debug log**: an optional log of every decision, written to `crash.log`.

Works with reflowable books (EPUB, FB2, TXT…) in single-page mode. PDFs and comics aren't supported. Tracking pauses in scroll mode and two-page mode.

## Installation

1. Download or clone this repository.
2. Copy the `wpmstats.koplugin` folder to KOReader's `plugins` folder:
   - Kobo: `.adds/koreader/plugins/`
   - Kindle: `koreader/plugins/`
   - Other devices: the `plugins` folder inside your KOReader install
3. Restart KOReader.

The menu appears under **Tools → Reading speed (WPM)** while a book is open.

## How it works

- **Only new pages count.** The plugin times the furthest page you've reached in this session. A page is counted when you turn forward exactly one page from it. Skipped pages (TOC jumps, links, search) are never counted.
- **Plausibility checks.** A page counts only if it has enough words (at least 30, and at least 40% of a typical page at your current font size, so title pages and short chapter endings are skipped), you spent no longer than the max time per page on it, and the implied speed is below the max plausible speed. This filters out walking away, skimming and flipping.
- **Going back.** A short look back (a few pages, a couple of minutes) keeps the current page's timing. A long one, such as a search or a TOC jump far back, discards that page. Re-reading behind your furthest page counts only after several plausible page turns in a row.
- **Pauses.** Timers pause while the device sleeps and while any menu, dialog or popup (dictionary, footnotes) covers the page.
- **Layout changes** (font, margins, rotation) restart timing without counting the current page.

## Settings

| Setting | Default | Range |
| --- | --- | --- |
| Max time per page | 10 min | 1–60 min |
| Max plausible speed | 1000 wpm | 300–3000 wpm |
| Pages interrupted by sleep | Ignore | Ignore / Count (excluding sleep time) |
| Time checking earlier pages | Include | Include / Exclude |
| Short detour: pages back | 3 | 1–20 |
| Short detour: time away | 2 min | 1–30 min |
| Pages in a row to confirm re-reading | 3 | 2–10 |
| Debug log | Off | On / Off |

The debug log writes a line to `crash.log` on every page turn, so leave it off except while testing. Lines start with `wpmstats:`.

## Known limitations

- The last page of a book is never counted.
- A word split across two pages may be counted twice.
- Word counts don't work for Chinese or Japanese text, which has no spaces between words.
- Menu time is accurate to about ±3 seconds per visit (menus are checked every 3 seconds).
- If KOReader's auto-standby is enabled, page times may be undercounted.

## Feedback

If your numbers look wrong, please [open an issue](https://github.com/FPsamuraiG/koreader-wpmstats/issues) and include the debug log:

1. Turn on **Settings → Debug log** and read as you normally would until the problem shows up.
2. Open KOReader's `crash.log` (on a Kobo: `.adds/koreader/crash.log`) and copy the lines that start with `wpmstats:`.
3. Paste them into the issue, with a few words on what you were doing (for example "looked up a word, then went back two pages").

Each line says which page was counted or skipped and why, which makes problems much easier to track down. Turn the debug log off again afterwards.

## Development

`wpmstats.koplugin/main.lua` holds all the logic. `tests/harness.lua` runs scenario tests against a mocked KOReader:

```bash
python tests/run_tests.py
```

The tests run on LuaJIT or Lua 5.1, the same Lua as KOReader, so code that only works in newer Lua versions fails here instead of on your device. The runner needs `luajit` on your PATH, the `lupa` Python package (`pip install lupa`, which includes LuaJIT), or `lua5.1`. It exits with code 1 if any test fails.

## License

Copyright (c) 2026 FPsamuraiG

This plugin is free software: you can redistribute it and/or modify it under the terms of the [GNU Affero General Public License](LICENSE), version 3 or (at your option) any later version, the same license as KOReader. If you share a modified version, keep the copyright notice and release your changes under the same license.

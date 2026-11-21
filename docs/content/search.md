---
title: Search
group: Structure
summary: What the conversation bar finds as you type — applications, files, settings, wallpapers, notes, tasks, web — and how results are ranked.
links: [panels, widgets, development, architecture]
---

# Search (`services/Search.qml`)

What you type in the [conversation bar](#panels) both talks to the pilot
and **searches**. The suggestions stack just above the bar, the best one
against it; ↑ enters the list, Enter opens the chosen line.

![The conversation bar, empty, before typing](screenshots/bar.webp)

## The sources

`Search.qml` knows nothing about content: it holds the query, hands it to
every source, collects their answers and ranks them in **one list**, all
types mixed — a relevant application must be able to beat a less relevant
file.

| Source | Finds | How |
| --- | --- | --- |
| `AppSource.qml` | Applications | The `.desktop` entries Quickshell already keeps in memory: no process, no index. The list fills asynchronously at startup, so the last query is replayed when it arrives. |
| `FileSource.qml` | Files and folders | `fd` in a separate process (never on the render thread), in the home directory and `/etc` (the NixOS configuration lives there). From 2 characters; 12 folders + 24 files at most, both searched at once; `.git`, `node_modules`, `target`, caches, `.venv`, the trashes, Docker's layers (`~/.local/share/docker`, 490,000 files: a search with no close match took over a second), icon themes, the inside of applications (Chromium's profile, Claude Desktop, Claude Code's state) and the wake-word training clips are skipped — about 7,000 entries remain. One query in flight at a time — the previous one is killed — and a 2 s guard cuts a huge tree short. Hidden and deep paths rank lower. |
| `SettingSource.qml` | Settings | Nothing to index on NixOS (the configuration is declarative): what can be found are the settings the shell already drives — volume, light/dark theme, accent, screenshot, interface screen, language. Each entry declares its `control` (which buttons the line shows) and whether it is `adjust`able: on those, ↑ ↓ change the value instead of moving through the list. |
| `WallpaperSource.qml` | Wallpapers | The videos the `wallpaper` command (from the NixOS configuration, which runs mpvpaper) finds in its folder. Typing “fond” lists them all; part of a name filters. Opening one swaps the wallpaper live. The list is kept a moment so the letters of one burst of typing reuse it. |
| `NoteSource.qml` | Notes | The notes of the “Notes” tab, read from `notes.json` (watched on disk, so no `anna` per letter), plus a “Create a note” line with what you typed (`anna notes add`). That line is always offered, outside the cutoff and the cap. |
| `TaskSource.qml` | Google Tasks | Only once the Google account is connected: one “Add to Google Tasks” line with what you typed (`Agenda.createTask`, into the list picked in the tasks pop-up). Always offered, outside the cutoff, at the far end of the list; starting with “tâche”, “task”, “todo” or “+” brings it first and Enter adds it directly instead of asking the pilot. “demain”/“tomorrow” or “aujourd’hui”/“today” at the start or the end sets the due day. |
| `WebSource.qml` | Web | No network request: it builds links to open. A query that already looks like an address is offered as is, first; otherwise one line per engine (Google by default — there is no system-wide default search engine on Linux, so it is a line of configuration). |

## Ranking

All sources score with the same pure functions, `services/Fuzzy.qml`. The
tiers are deliberately far apart, so the kind of match weighs more than the
length of the text:

| Match | Score |
| --- | --- |
| The text starts with the query | 1000 − length |
| The query starts a word inside the text (after a space, `-`, `_`, `.`, `/`, `:`) | 700 − position |
| The query is somewhere in the middle of a word | 400 − position |
| All the letters, in order, not contiguous | 150 |

Then `Search.qml`:

- adds a **type bonus** at equal match — applications +120, settings +60 —
  so the folder `fish` no longer beats Firefox on “fi”;
- keeps only results within **350** of the best local one (its tier and the
  top of the next), not mid-word fragments when a prefix exists;
- caps the list at **12** lines; once there are **3** local results, the web
  shrinks to a single line.

## Stale answers

Every query carries a number. An answer that does not carry the current
number is stale and thrown away — a slow source (`fd`) can never show the
results of a previous keystroke. A 130 ms debounce protects `fd`; the other
sources answer in under a millisecond.

**One list per keystroke.** The sources do not answer together
(applications and settings at once, `fd` and the wallpaper list later), and
publishing at every answer moved the lines under the cursor. So the list is
published once **every source has answered**, or after **600 ms** at most,
and then no longer changes until the next keystroke: a later answer is
dropped. Meanwhile the previous keystroke's list stays on screen (so it does
not fold and unfold at every letter) and `Search.loading` is true: the bar
does not let ↑ into that list, it keeps the press and selects the first
line of the new list when it arrives.

These behaviours are covered by `tests/tst_search.qml` and
`tests/tst_fuzzy.qml` (see [Development](#development)).

## Adding a type of result

Four steps, no other file to touch:

1. `services/<Name>Source.qml`: `search(query, seq)` → `produced(seq,
   items)`, and `activate(item, actionId)`;
2. `services/qmldir`: declare the component;
3. `services/Search.qml`: a property and an entry in `sources`;
4. `panels/Bar.qml`: the type's icon and label (and a stub in `tests/stubs`,
   declared in `tests/run.sh`).

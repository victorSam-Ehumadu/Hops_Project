# Presentation generators

Scripts that build the two presentation deliverables in `docs/`:

| Build this | Run |
|---|---|
| `Group 18 Presentation.pptx` | `python docs/generators/build_deck.py` |
| `Group 18 Presentation Practice Pack.docx` | `python docs/generators/build_pack.py` |

Needs `python-pptx`, `python-docx` and (for the figures) `matplotlib`.

## Why these are in the repo

An earlier version of them was not. They lived in a scratch directory,
that directory was cleared, and the only remaining copy of the deck was
the `.pptx` itself — no way to regenerate it, and no record of how it had
been built. These were reconstructed by reading the committed files back
out. **Keep them here.**

## Layout

```
build_deck.py        slide layout and the palette
deck_content.py      the 38 slides as data — text, speaker notes, timings
deck_figures.py      regenerates the seven diagrams into assets/
build_pack.py        page setup and styles for the practice pack
pack_content.py      the pack as an ordered list of blocks
extract_from_pptx.py rebuilds deck_content.py from the committed .pptx
extract_from_docx.py rebuilds pack_content.py from the committed .docx
assets/              the figures, the logo, and the watermark
```

Content is kept separate from layout so that fixing a number in a speaker
note does not mean reading layout code, and moving a box does not mean
scrolling past 38 slides of prose.

## Editing

**Normal case — change the wording or a number.** Edit `deck_content.py`
or `pack_content.py`, run the matching build script, then export to PDF
and read it back before committing. That last step is not optional; it has
caught a struck-through slide title, two blank pages, a one-row table
widow and several overlapping diagrams that all looked fine in the source.

**If someone edited the `.docx` or `.pptx` directly in Word or
PowerPoint**, their edits are only in that file. Pull them back in with
`extract_from_pptx.py` / `extract_from_docx.py` *before* running a build,
or the next build silently discards them.

**If a diagram changes**, run `deck_figures.py` and then `build_deck.py` —
the deck embeds the PNGs, so regenerating a figure alone changes nothing
in the deck. `d_survey.png` is computed from
`docs/Hops User Testing Part 1.csv` at build time, so it moves on its own
whenever that data does.

## Two things that will bite

**Figures must be transparent-background and light-ink.** The deck's
ground is dark. A figure saved with the matplotlib default white
background sits in a glaring pale box — which is the whole problem the
dark palette exists to avoid. `deck_figures.py` already does this; a new
figure added by hand will not unless you copy the `save()` helper.

**The palette is the app's own theme, inverted.** `app_theme.dart` defines
Hops Default as `#165c6f` on `#e2fffe` with `#002020` text. The deck uses
`#002020` as the ground and the pale cyan as the ink, because a near-white
slide in a darkened room is painful and wrecks night vision right before a
live demo of a phone screen. Lighten a colour if it does not read on dark;
do not flip the ground back.

## Round-trip check

Both generators were verified to reproduce the committed files exactly —
all 38 slides matching on text, pictures, speaker notes and background,
and all 254 pack blocks matching on text, style and run formatting. If you
change a build script, re-run that check rather than assuming.

# Re-derives deck_content.py from the committed .pptx.
#
#   python docs/generators/extract_from_pptx.py
#
# You should not normally need this. It exists for one situation: someone
# edited the deck directly in PowerPoint, and those edits now need to get
# back into the generator rather than being silently overwritten the next
# time build_deck.py runs.
#
# It was also how this generator was first rebuilt, after the original
# scripts were lost and the .pptx was all that remained.
#
# Round-trip check after running it:
#     python docs/generators/build_deck.py   (to a scratch path)
# then compare text, pictures, notes and background per slide. They should
# match exactly; a generator that does not reproduce the committed file is
# worse than no generator.
import io
import os
import re
from pptx import Presentation
from pptx.util import Emu

SRC = r"C:\Projects\Hops_Project\docs\Group 18 Presentation.pptx"
OUT = r"C:\Projects\Hops_Project\docs\generators\deck_content.py"

FIG_FOR_SLIDE = {11: 'd_noserver.png', 13: 'd_radios.png', 15: 'd_packet.png',
                 18: 'd_mesh.png', 23: 'd_rotate.png', 27: 'd_survey.png',
                 36: 'd_pyramid.png'}

prs = Presentation(SRC)


def lines_of(shape):
    out = []
    for p in shape.text_frame.paragraphs:
        runs = [(r.text, bool(r.font.bold), r.font.size.pt if r.font.size else None)
                for r in p.runs if r.text]
        if runs:
            out.append(runs)
    return out


def q(s):
    """Emit a Python string literal, preferring readable triple-quotes."""
    if '\n' in s:
        body = s.replace('\\', '\\\\').replace('"""', '\\"\\"\\"')
        return '"""%s"""' % body
    return repr(s)


specs = []
for idx, s in enumerate(prs.slides, 1):
    bg = str(s.background.fill.fore_color.rgb)
    notes = s.notes_slide.notes_text_frame.text if s.has_notes_slide else ''
    figs = [sh for sh in s.shapes if sh.shape_type == 13
            and Emu(sh.width).inches > 5]
    texts = [sh for sh in s.shapes if sh.has_text_frame
             and sh.text_frame.text.strip()]
    flat = []
    for sh in texts:
        for para in lines_of(sh):
            flat.append(para)

    def plain(p):
        return ''.join(t for t, _, _ in p)

    def size(p):
        return max([sz for _, _, sz in p if sz] or [0])

    eyebrow = next((plain(p) for p in flat if 'SEGMENT' in plain(p).upper()
                    and size(p) <= 12), None)
    dur = next((plain(p) for p in flat if size(p) == 11
                and re.fullmatch(r'\d+\s*(min|sec)', plain(p).strip())), None)

    seg = member = live = None
    if eyebrow:
        parts = [x.strip() for x in eyebrow.split('·')]
        seg = int(re.sub(r'\D', '', parts[0]))
        member = parts[1].title() if len(parts) > 1 else None
        live = len(parts) > 2 and parts[2].upper() == 'LIVE'

    spec = {'n': idx, 'bg': bg, 'notes': notes, 'seg': seg, 'member': member,
            'dur': dur, 'live': live}

    if idx == 1:
        spec['kind'] = 'title'
    elif idx == 2:
        spec['kind'] = 'running_order'
    elif figs:
        spec['kind'] = 'visual'
        spec['image'] = FIG_FOR_SLIDE[idx]
        spec['width'] = round(Emu(figs[0].width).inches, 2)
        spec['title'] = next(plain(p) for p in flat if size(p) >= 27)
        caps = [plain(p) for p in flat if size(p) == 13]
        spec['caption'] = caps[-1] if caps else ''
    elif bg == '00161A' and idx == len(prs.slides):
        spec['kind'] = 'closing'
    elif bg == '00161A' and any(size(p) >= 60 for p in flat):
        spec['kind'] = 'divider'
        spec['num'] = next(plain(p) for p in flat if size(p) == 13)
        spec['label'] = next(plain(p) for p in flat if size(p) >= 60)
        spec['blurb'] = next(plain(p) for p in flat if size(p) == 20)
    elif bg == '00161A':
        spec['kind'] = 'quote'
        spec['big'] = next(plain(p) for p in flat if size(p) >= 40)
        spec['sub'] = next(plain(p) for p in flat if size(p) == 20)
    elif any(size(p) == 52 for p in flat):
        spec['kind'] = 'stat'
        spec['title'] = next(plain(p) for p in flat if size(p) >= 27)
        vals = [plain(p) for p in flat if size(p) == 52]
        keys = [plain(p) for p in flat if size(p) == 13]
        spec['stats'] = list(zip(vals, keys))
    elif spec.get('live'):
        spec['kind'] = 'demo'
        spec['title'] = next(plain(p) for p in flat if size(p) >= 27)
        steps = [plain(p) for p in flat if size(p) == 19]
        spec['steps'] = [re.sub(r'^\d+\.\s*', '', x) for x in steps]
        fb = next((p for p in flat if size(p) == 15), None)
        spec['fallback'] = ''.join(t for t, _, _ in fb[1:]).strip() if fb else ''
    else:
        spec['kind'] = 'content'
        spec['title'] = next(plain(p) for p in flat if size(p) >= 27)
        kick = [plain(p) for p in flat if size(p) == 21]
        spec['kicker'] = kick[0] if kick else None
        bl = []
        for p in flat:
            if size(p) != 19:
                continue
            lead = ''.join(t for t, b, _ in p if b)
            rest = ''.join(t for t, b, _ in p if not b)
            bl.append((lead.strip(), rest.strip()) if lead else rest.strip())
        spec['bullets'] = bl
        # 14pt, not 15 — 15 is the demo slides' fallback line.
        tail = [plain(p) for p in flat if size(p) == 14]
        spec['mono_tail'] = tail[0] if tail else None
    specs.append(spec)

# ── emit ─────────────────────────────────────────────────────────────
buf = ['# Slide content for the Group 18 presentation deck.',
       '#',
       '# Data only — build_deck.py owns the layout. Extracted from the',
       '# committed .pptx so the generator reproduces it exactly.',
       '#',
       '# Each entry is one slide, in order. "kind" selects the builder.',
       '',
       'SLIDES = [']
for sp in specs:
    buf.append('    {')
    buf.append('        "kind": %r, "n": %d,' % (sp['kind'], sp['n']))
    for k in ('seg', 'member', 'dur', 'live', 'title', 'kicker', 'num',
              'label', 'blurb', 'big', 'sub', 'image', 'width', 'caption',
              'mono_tail', 'fallback'):
        if sp.get(k) not in (None, '', False):
            buf.append('        "%s": %s,' % (k, q(sp[k]) if isinstance(sp[k], str) else repr(sp[k])))
    for k in ('bullets', 'steps', 'stats'):
        if sp.get(k):
            buf.append('        "%s": [' % k)
            for item in sp[k]:
                if isinstance(item, tuple):
                    buf.append('            (%s, %s),' % (q(item[0]), q(item[1])))
                else:
                    buf.append('            %s,' % q(item))
            buf.append('        ],')
    buf.append('        "notes": %s,' % q(sp['notes']))
    buf.append('    },')
buf.append(']')

os.makedirs(os.path.dirname(OUT), exist_ok=True)
io.open(OUT, 'w', encoding='utf-8', newline='').write('\n'.join(buf) + '\n')
print('wrote %s  (%d slides)' % (OUT, len(specs)))
from collections import Counter
print(Counter(s['kind'] for s in specs))

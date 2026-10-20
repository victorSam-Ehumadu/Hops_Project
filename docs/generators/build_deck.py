# Builds docs/Group 18 Presentation.pptx.
#
#   python docs/generators/build_deck.py
#
# Lives in the repo deliberately. An earlier version of this script lived
# only in a scratch directory, which was cleared — leaving the .pptx as
# the sole source of truth and no way to regenerate it. Keep it here.
#
# Layout only; the slide content is data in deck_content.py, and the
# figures are PNGs in assets/ (regenerate those with deck_figures.py).
#
# Palette: the app's own "Hops Default" theme, INVERTED. app_theme.dart
# defines it as primary #165c6f on background #e2fffe with #002020 text.
# A deck is shown in a darkened room, so that is the wrong way round — a
# near-white slide between two dark ones is painful to look at and wrecks
# night vision right before a live demo of a phone screen. The ground here
# is the app's own #002020 lifted slightly so panels read against it, and
# the app's pale cyan becomes the ink.
import os
import sys

from pptx import Presentation
from pptx.util import Inches, Pt
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, 'assets')
OUT = os.environ.get(
    'DECK_OUT',
    os.path.join(os.path.dirname(HERE), 'Group 18 Presentation.pptx'))

sys.path.insert(0, HERE)
from deck_content import SLIDES  # noqa: E402

# ── Palette ───────────────────────────────────────────────────────────
PAPER = RGBColor(0x04, 0x28, 0x2D)   # content slides
DEEP = RGBColor(0x00, 0x16, 0x1A)    # title / divider / quote / closing
PANEL = RGBColor(0x0A, 0x35, 0x3C)   # stat tiles
INK = RGBColor(0xE2, 0xFF, 0xFE)     # app background colour, now the ink
INKSOF = RGBColor(0x9C, 0xC8, 0xCC)
INKFNT = RGBColor(0x6E, 0x9B, 0xA0)
SIGNAL = RGBColor(0xFF, 0x8A, 0x5C)  # signal orange, lifted for dark
PHOS = RGBColor(0x5F, 0xD3, 0xD8)    # primary #165c6f, lifted for dark
RULE = RGBColor(0x1C, 0x50, 0x59)
WHITE = RGBColor(0xFF, 0xFF, 0xFF)

F_HEAD = "Segoe UI Semibold"
F_BODY = "Segoe UI"
F_MONO = "Consolas"

W, H = Inches(13.333), Inches(7.5)
MARGIN = Inches(0.85)

LOGO = os.path.join(ASSETS, 'hops_logo.png')
WATERMARK = os.path.join(ASSETS, 'hops_watermark.png')

prs = Presentation()
prs.slide_width, prs.slide_height = W, H
BLANK = prs.slide_layouts[6]


# ── Primitives ────────────────────────────────────────────────────────
def bg(slide, color):
    f = slide.background.fill
    f.solid()
    f.fore_color.rgb = color


def notes(slide, text):
    slide.notes_slide.notes_text_frame.text = text


def box(slide, l, t, w, h):
    tf = slide.shapes.add_textbox(l, t, w, h).text_frame
    tf.word_wrap = True
    tf.margin_left = tf.margin_right = tf.margin_top = tf.margin_bottom = 0
    return tf


def run(para, text, size, font=F_BODY, color=INK, bold=False, space=None,
        caps=False):
    r = para.add_run()
    r.text = text.upper() if caps else text
    r.font.size = Pt(size)
    r.font.name = font
    r.font.color.rgb = color
    r.font.bold = bold
    if space is not None:
        # Letter-spacing: python-pptx exposes no API for it.
        r.font._rPr.set('spc', str(int(space * 100)))
    return r


def rule(slide, t, color=RULE, h=Pt(1), l=None, w=None):
    l = MARGIN if l is None else l
    w = (W - 2 * MARGIN) if w is None else w
    sh = slide.shapes.add_shape(1, l, t, w, h)   # 1 = rectangle
    sh.fill.solid()
    sh.fill.fore_color.rgb = color
    sh.line.fill.background()
    sh.shadow.inherit = False
    return sh


def title_pt(text):
    """Keep a slide title on one line. ~44 chars fit at 38pt in 11.4in."""
    n = len(text)
    return 38 if n <= 44 else 32 if n <= 56 else 27


def slide_title(slide, text):
    tf = box(slide, MARGIN, Inches(0.95), Inches(11.4), Inches(1.0))
    run(tf.paragraphs[0], text, title_pt(text), F_HEAD, INK, bold=True)
    rule(slide, Inches(1.95), INK, Pt(2))


def watermark(slide):
    """A faint Hops mark, bottom-right.

    Opacity is baked into the PNG (~32%): python-pptx has no opacity API
    for pictures, and the XML alpha hack is fragile across PowerPoint
    versions. Bottom-right specifically — the top-right carries the
    segment timing and the bottom-left strip carries the monospace
    footnote, so this corner is the one nothing else claims.
    """
    size = Inches(0.62)
    slide.shapes.add_picture(WATERMARK, W - size - Inches(0.34),
                             H - size - Inches(0.22), height=size)


def eyebrow(slide, seg, member, dur=None, live=False):
    tf = box(slide, MARGIN, Inches(0.5), Inches(8.0), Inches(0.4))
    p = tf.paragraphs[0]
    run(p, "Segment %02d" % seg, 11, F_MONO, SIGNAL, space=1.5, caps=True)
    run(p, "   ·   ", 11, F_MONO, RULE)
    run(p, member, 11, F_MONO, INKFNT, space=1.5, caps=True)
    if live:
        run(p, "   ·   ", 11, F_MONO, RULE)
        run(p, "Live", 11, F_MONO, SIGNAL, space=1.5, caps=True)
    if dur:
        tf = box(slide, W - MARGIN - Inches(2.0), Inches(0.5),
                 Inches(2.0), Inches(0.4))
        p = tf.paragraphs[0]
        p.alignment = PP_ALIGN.RIGHT
        run(p, dur, 11, F_MONO, INKFNT, space=1.0)


def new(dark=False):
    s = prs.slides.add_slide(BLANK)
    bg(s, DEEP if dark else PAPER)
    return s


# ── Slide builders ────────────────────────────────────────────────────
def build_title(d):
    s = new(dark=True)
    run(box(s, MARGIN, Inches(2.0), Inches(10.5), Inches(1.0)).paragraphs[0],
        "Group 18  ·  IT Project  ·  Implementation Phase", 13, F_MONO,
        SIGNAL, space=1.4, caps=True)
    pic = s.shapes.add_picture(LOGO, Inches(0), Inches(2.25), height=Inches(2.0))
    pic.left = int(W - MARGIN - pic.width)
    run(box(s, MARGIN, Inches(2.5), Inches(11.5), Inches(2.0)).paragraphs[0],
        "HOPS", 96, F_HEAD, WHITE, bold=True, space=-1)
    run(box(s, MARGIN, Inches(4.3), Inches(9.6), Inches(1.4)).paragraphs[0],
        "A campus safety network that works with no internet, no mobile "
        "data and no signal.", 24, F_BODY, INKSOF)
    run(box(s, MARGIN, Inches(6.2), Inches(11.5), Inches(0.6)).paragraphs[0],
        "Victor  ·  Hlonipha  ·  Sade  ·  Thrishen  ·  Elijah  ·  "
        "Nabihah  ·  Jocelyn", 12, F_MONO, INKFNT, space=1.0)
    notes(s, d['notes'])


def build_running_order(d):
    s = new()
    run(box(s, MARGIN, Inches(0.55), Inches(11.5), Inches(0.9)).paragraphs[0],
        "How this hour works", 40, F_HEAD, INK, bold=True)
    rule(s, Inches(1.45), INK, Pt(2))
    run(box(s, MARGIN, Inches(1.75), Inches(11.6), Inches(0.8)).paragraphs[0],
        "Seven of us, fourteen segments. Each person speaks twice: once to "
        "explain something, once to show it running.", 19, F_BODY, INKSOF)
    rows = [
        ("Round one", "The problem, the architecture, the protocol, safety, security", "~18 min"),
        ("Round two", "Live software on real devices, plus engineering depth", "~21 min"),
        ("Your questions", "The rest of the hour — we would rather spend it here", "~20 min"),
    ]
    y = Inches(2.9)
    for name, desc, dur in rows:
        run(box(s, MARGIN, y, Inches(3.1), Inches(0.5)).paragraphs[0],
            name, 22, F_HEAD, SIGNAL, bold=True)
        run(box(s, MARGIN + Inches(3.2), y + Inches(0.06), Inches(6.9),
                Inches(0.9)).paragraphs[0], desc, 17, F_BODY, INKSOF)
        tf = box(s, W - MARGIN - Inches(1.5), y + Inches(0.06), Inches(1.5), Inches(0.5))
        tf.paragraphs[0].alignment = PP_ALIGN.RIGHT
        run(tf.paragraphs[0], dur, 15, F_MONO, INKFNT)
        rule(s, y + Inches(1.0))
        y += Inches(1.25)
    run(box(s, MARGIN, Inches(6.75), Inches(11.5), Inches(0.5)).paragraphs[0],
        "Everything you see demonstrated is running on these phones. "
        "Nothing is on a server.", 15, F_MONO, PHOS, space=0.4)
    notes(s, d['notes'])


def build_divider(d):
    s = new(dark=True)
    run(box(s, MARGIN, Inches(2.6), Inches(11.5), Inches(0.6)).paragraphs[0],
        d['num'], 13, F_MONO, SIGNAL, space=1.6, caps=True)
    run(box(s, MARGIN, Inches(3.1), Inches(11.5), Inches(1.3)).paragraphs[0],
        d['label'], 60, F_HEAD, WHITE, bold=True)
    run(box(s, MARGIN, Inches(4.5), Inches(9.0), Inches(1.0)).paragraphs[0],
        d['blurb'], 20, F_BODY, INKSOF)
    notes(s, d['notes'])


def build_content(d):
    s = new()
    eyebrow(s, d['seg'], d['member'], d.get('dur'))
    slide_title(s, d['title'])
    y = Inches(2.2)
    if d.get('kicker'):
        run(box(s, MARGIN, y, Inches(10.6), Inches(0.9)).paragraphs[0],
            d['kicker'], 21, F_BODY, PHOS)
        y += Inches(0.95)
    tf = box(s, MARGIN, y, Inches(11.4), Inches(4.0))
    first = True
    for b in d['bullets']:
        p = tf.paragraphs[0] if first else tf.add_paragraph()
        first = False
        p.space_after = Pt(14)
        if isinstance(b, (list, tuple)):
            run(p, b[0], 19, F_HEAD, INK, bold=True)
            run(p, "  " + b[1], 19, F_BODY, INKSOF)
        else:
            run(p, b, 19, F_BODY, INKSOF)
    if d.get('mono_tail'):
        rule(s, Inches(6.55))
        run(box(s, MARGIN, Inches(6.75), Inches(11.4), Inches(0.5)).paragraphs[0],
            d['mono_tail'], 14, F_MONO, PHOS, space=0.3)
    notes(s, d['notes'])


def build_stat(d):
    s = new()
    eyebrow(s, d['seg'], d['member'], d.get('dur'))
    slide_title(s, d['title'])
    stats = d['stats']
    cols = 2 if len(stats) <= 4 else 3
    cw = (W - 2 * MARGIN) / cols
    rh = Inches(1.45)
    for i, (v, k) in enumerate(stats):
        cx = MARGIN + cw * (i % cols)
        cy = Inches(2.45) + rh * (i // cols)
        # A panel behind each figure, so the numbers read as tiles rather
        # than floating text on a large dark field.
        card = s.shapes.add_shape(1, cx - Inches(0.18), cy - Inches(0.22),
                                  cw - Inches(0.35), Inches(1.18))
        card.fill.solid()
        card.fill.fore_color.rgb = PANEL
        card.line.color.rgb = RULE
        card.line.width = Pt(0.75)
        card.shadow.inherit = False
        run(box(s, cx, cy, cw - Inches(0.4), Inches(0.75)).paragraphs[0],
            v, 52, F_HEAD, INK, bold=True)
        run(box(s, cx, cy + Inches(0.78), cw - Inches(0.4), Inches(0.55)).paragraphs[0],
            k, 13, F_MONO, INKFNT, space=0.8, caps=True)
    notes(s, d['notes'])


def build_quote(d):
    s = new(dark=True)
    eyebrow_dark(s, d)
    run(box(s, MARGIN, Inches(2.1), Inches(11.4), Inches(2.6)).paragraphs[0],
        d['big'], 44, F_HEAD, WHITE, bold=True)
    run(box(s, MARGIN, Inches(5.1), Inches(10.4), Inches(1.2)).paragraphs[0],
        d['sub'], 20, F_BODY, INKSOF)
    notes(s, d['notes'])


def eyebrow_dark(s, d):
    tf = box(s, MARGIN, Inches(0.5), Inches(8.0), Inches(0.4))
    p = tf.paragraphs[0]
    run(p, "Segment %02d" % d['seg'], 11, F_MONO, SIGNAL, space=1.5, caps=True)
    run(p, "   ·   ", 11, F_MONO, RULE)
    run(p, d['member'], 11, F_MONO, INKFNT, space=1.5, caps=True)
    if d.get('dur'):
        tf = box(s, W - MARGIN - Inches(2.0), Inches(0.5), Inches(2.0), Inches(0.4))
        tf.paragraphs[0].alignment = PP_ALIGN.RIGHT
        run(tf.paragraphs[0], d['dur'], 11, F_MONO, INKFNT, space=1.0)


def build_demo(d):
    s = new()
    eyebrow(s, d['seg'], d['member'], d.get('dur'), live=True)
    slide_title(s, d['title'])
    tf = box(s, MARGIN, Inches(2.25), Inches(11.4), Inches(3.9))
    first = True
    for i, st in enumerate(d['steps'], 1):
        p = tf.paragraphs[0] if first else tf.add_paragraph()
        first = False
        p.space_after = Pt(13)
        run(p, "%d. " % i, 19, F_MONO, SIGNAL, bold=True)
        run(p, st, 19, F_BODY, INKSOF)
    rule(s, Inches(6.35), SIGNAL, Pt(2), l=MARGIN, w=Inches(11.4))
    tf = box(s, MARGIN, Inches(6.55), Inches(11.4), Inches(0.7))
    p = tf.paragraphs[0]
    run(p, "If it fails:  ", 15, F_MONO, SIGNAL, bold=True, space=0.5, caps=True)
    run(p, d['fallback'], 15, F_BODY, INKSOF)
    notes(s, d['notes'])


def build_visual(d):
    """A slide whose argument IS the picture.

    Deliberately no bullets: if a diagram needs a list beside it then the
    diagram is not carrying its weight, and the audience reads instead of
    listening.
    """
    s = new()
    eyebrow(s, d['seg'], d['member'], d.get('dur'))
    slide_title(s, d['title'])
    top = Inches(d.get('top', 2.25))
    pic = s.shapes.add_picture(os.path.join(ASSETS, d['image']),
                               Inches(0), top, width=Inches(d['width']))
    pic.left = int((W - pic.width) / 2)
    if d.get('caption'):
        tf = box(s, MARGIN, top + pic.height + Inches(0.16),
                 Inches(11.4), Inches(0.5))
        tf.paragraphs[0].alignment = PP_ALIGN.CENTER
        run(tf.paragraphs[0], d['caption'], 13, F_BODY, INKSOF)
    notes(s, d['notes'])


def build_closing(d):
    s = new(dark=True)
    run(box(s, MARGIN, Inches(2.3), Inches(11.5), Inches(1.4)).paragraphs[0],
        "Questions", 72, F_HEAD, WHITE, bold=True)
    run(box(s, MARGIN, Inches(3.9), Inches(9.8), Inches(1.6)).paragraphs[0],
        "The phones are unlocked and the admin app is signed in. If you "
        "would rather see something than hear about it, ask.", 22, F_BODY, INKSOF)
    run(box(s, MARGIN, Inches(6.3), Inches(11.5), Inches(0.5)).paragraphs[0],
        "Group 18  ·  Hops  ·  github — b1t-0f-v1k", 12, F_MONO, INKFNT, space=1.0)
    notes(s, d['notes'])


BUILDERS = {
    'title': build_title, 'running_order': build_running_order,
    'divider': build_divider, 'content': build_content, 'stat': build_stat,
    'quote': build_quote, 'demo': build_demo, 'visual': build_visual,
    'closing': build_closing,
}

if __name__ == '__main__':
    for d in SLIDES:
        BUILDERS[d['kind']](d)
    # Every slide but the title, which already carries the logo full size.
    for i, s in enumerate(prs.slides):
        if i:
            watermark(s)
    prs.save(OUT)
    print('saved:', OUT)
    print('slides:', len(SLIDES))

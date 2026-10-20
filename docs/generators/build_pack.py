# Builds docs/Group 18 Presentation Practice Pack.docx.
#
#   python docs/generators/build_pack.py
#
# Lives in the repo deliberately — see build_deck.py's note on why.
#
# Layout and styles only; the content is data in pack_content.py.
#
# House style matches Phase 2 through 5: A4, 1in margins, Heading 1 in
# 0F4761. Section 3 gives each of the seven presenters exactly one page,
# which is the constraint that drives the tight 10pt bullets — a member
# whose notes spill onto a second page cannot print just their own sheet.
import os
import sys

import docx
from docx.shared import Pt, Inches, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.oxml.ns import qn
from docx.oxml import OxmlElement

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.environ.get(
    'PACK_OUT',
    os.path.join(os.path.dirname(HERE),
                 'Group 18 Presentation Practice Pack.docx'))

sys.path.insert(0, HERE)
from pack_content import BLOCKS  # noqa: E402

ALIGN = {
    'CENTER (1)': WD_ALIGN_PARAGRAPH.CENTER,
    'RIGHT (2)': WD_ALIGN_PARAGRAPH.RIGHT,
    'JUSTIFY (3)': WD_ALIGN_PARAGRAPH.JUSTIFY,
}

doc = docx.Document()

# A4 with 1in margins, as every other document in docs/.
for s in doc.sections:
    s.page_width, s.page_height = Inches(8.27), Inches(11.69)
    s.left_margin = s.right_margin = s.top_margin = s.bottom_margin = Inches(1.0)

normal = doc.styles['Normal']
normal.font.name = 'Aptos'
normal.font.size = Pt(11)
normal.paragraph_format.space_after = Pt(6)
normal.paragraph_format.line_spacing = 1.08


def shade(cell, fill='E7ECEA'):
    el = OxmlElement('w:shd')
    el.set(qn('w:fill'), fill)
    cell._tc.get_or_add_tcPr().append(el)


def no_row_split(t, keep_whole_upto=7):
    """Stop a table row breaking across a page, and keep a short table
    whole — a lone trailing row on an otherwise blank page reads as a
    layout fault, which is exactly what the first build of this produced."""
    for row in t.rows:
        row._tr.get_or_add_trPr().append(OxmlElement('w:cantSplit'))
    if len(t.rows) <= keep_whole_upto:
        for row in t.rows:
            for cell in row.cells:
                for par in cell.paragraphs:
                    par.paragraph_format.keep_with_next = True


def emit_paragraph(b):
    style = b['style']
    p = doc.add_paragraph(style=None if style == 'Normal' else style)
    for r in b['runs']:
        run = p.add_run(r['text'])
        run.bold = r.get('bold', False)
        run.italic = r.get('italic', False)
        if r.get('size'):
            run.font.size = Pt(r['size'])
        if r.get('color'):
            run.font.color.rgb = RGBColor.from_string(r['color'])
    pf = p.paragraph_format
    if b.get('indent') is not None:
        pf.left_indent = Inches(b['indent'])
    if b.get('after') is not None:
        pf.space_after = Pt(b['after'])
    if b.get('before') is not None:
        pf.space_before = Pt(b['before'])
    if b.get('brk'):
        pf.page_break_before = True
    if b.get('align') in ALIGN:
        p.alignment = ALIGN[b['align']]
    if style == 'List Bullet':
        pf.line_spacing = 1.05


def emit_table(b):
    rows = b['rows']
    t = doc.add_table(rows=1, cols=len(rows[0]))
    t.style = 'Table Grid'
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    for i, head in enumerate(rows[0]):
        c = t.rows[0].cells[i]
        c.text = ''
        r = c.paragraphs[0].add_run(head)
        r.bold = True
        r.font.size = Pt(9.5)
        c.paragraphs[0].paragraph_format.space_after = Pt(2)
        shade(c)
    for row in rows[1:]:
        cells = t.add_row().cells
        for i, val in enumerate(row):
            cells[i].text = ''
            par = cells[i].paragraphs[0]
            r = par.add_run(val)
            r.font.size = Pt(10)
            par.paragraph_format.space_after = Pt(2)
    widths = b.get('widths')
    if widths and all(w for w in widths):
        for row in t.rows:
            for i, w in enumerate(widths):
                row.cells[i].width = Inches(w)
    no_row_split(t)
    doc.add_paragraph().paragraph_format.space_after = Pt(4)


if __name__ == '__main__':
    for b in BLOCKS:
        if b['t'] == 'table':
            emit_table(b)
        else:
            emit_paragraph(b)
    doc.save(OUT)
    print('saved:', OUT)
    print('blocks:', len(BLOCKS))

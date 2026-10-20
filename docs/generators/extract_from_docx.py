# Re-derives pack_content.py from the committed practice pack .docx.
#
#   python docs/generators/extract_from_docx.py
#
# Same purpose as extract_from_pptx.py: you only need this when someone
# has edited the pack directly in Word and those edits must get back into
# the generator rather than being overwritten by the next build.
#
# Walks the document BODY rather than document.paragraphs, because the
# latter silently drops tables — and the pack interleaves six of them
# among the prose, so their position in the flow matters.
import io
import os

import docx
from docx.table import Table
from docx.text.paragraph import Paragraph

SRC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   'Group 18 Presentation Practice Pack.docx')
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'pack_content.py')


def body_items(doc):
    """Yield Paragraph / Table objects in true document order."""
    for child in doc.element.body.iterchildren():
        if child.tag.endswith('}p'):
            yield Paragraph(child, doc)
        elif child.tag.endswith('}tbl'):
            yield Table(child, doc)


def runs_of(par):
    out = []
    for r in par.runs:
        if not r.text:
            continue
        col = None
        try:
            if r.font.color is not None and r.font.color.rgb is not None:
                col = str(r.font.color.rgb)
        except Exception:
            col = None
        out.append({
            'text': r.text,
            'bold': bool(r.font.bold),
            'italic': bool(r.font.italic),
            'size': r.font.size.pt if r.font.size else None,
            'color': col,
        })
    return out


def q(s):
    if '\n' in s:
        return '"""%s"""' % s.replace('\\', '\\\\').replace('"""', '\\"\\"\\"')
    return repr(s)


def main():
    doc = docx.Document(SRC)
    blocks = []
    for item in body_items(doc):
        if isinstance(item, Table):
            rows = []
            for row in item.rows:
                rows.append([c.text for c in row.cells])
            widths = []
            if item.rows:
                for c in item.rows[0].cells:
                    widths.append(round(c.width.inches, 2) if c.width else None)
            blocks.append({'t': 'table', 'rows': rows, 'widths': widths})
            continue

        rs = runs_of(item)
        if not rs and not item.text.strip():
            continue
        pf = item.paragraph_format
        blocks.append({
            't': 'p',
            'style': item.style.name,
            'runs': rs,
            'indent': round(pf.left_indent.inches, 3) if pf.left_indent else None,
            'after': pf.space_after.pt if pf.space_after else None,
            'before': pf.space_before.pt if pf.space_before else None,
            'brk': bool(pf.page_break_before),
            'align': str(pf.alignment) if pf.alignment else None,
        })

    buf = ['# Content for the Group 18 presentation practice pack.',
           '#',
           '# Data only — build_pack.py owns the page setup and styles.',
           '# Extracted from the committed .docx so the generator',
           '# reproduces it exactly. Blocks are in document order;',
           '# "t" is "p" for a paragraph or "table" for a table.',
           '',
           'BLOCKS = [']
    for b in blocks:
        if b['t'] == 'table':
            buf.append('    {"t": "table", "widths": %r, "rows": [' % (b['widths'],))
            for row in b['rows']:
                buf.append('        [%s],' % ', '.join(q(c) for c in row))
            buf.append('    ]},')
        else:
            bits = ['"t": "p"', '"style": %r' % b['style']]
            for k in ('indent', 'after', 'before', 'align'):
                if b[k] is not None:
                    bits.append('"%s": %r' % (k, b[k]))
            if b['brk']:
                bits.append('"brk": True')
            buf.append('    {%s, "runs": [' % ', '.join(bits))
            for r in b['runs']:
                rb = ['"text": %s' % q(r['text'])]
                for k in ('bold', 'italic'):
                    if r[k]:
                        rb.append('"%s": True' % k)
                for k in ('size', 'color'):
                    if r[k] is not None:
                        rb.append('"%s": %r' % (k, r[k]))
                buf.append('        {%s},' % ', '.join(rb))
            buf.append('    ]},')
    buf.append(']')

    io.open(OUT, 'w', encoding='utf-8', newline='').write('\n'.join(buf) + '\n')
    n_t = sum(1 for b in blocks if b['t'] == 'table')
    print('wrote %s' % OUT)
    print('  %d blocks (%d paragraphs, %d tables)'
          % (len(blocks), len(blocks) - n_t, n_t))


if __name__ == '__main__':
    main()

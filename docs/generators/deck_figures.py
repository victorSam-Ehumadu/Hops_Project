# Regenerates the deck's seven diagrams into assets/.
#
#   python docs/generators/deck_figures.py
#
# The committed PNGs in assets/ are what build_deck.py actually embeds, so
# running this is only needed when a diagram's content changes — most
# often d_survey.png, which is computed from the acceptance-study CSV and
# so moves whenever that data does.
#
# Everything is drawn on a TRANSPARENT background with light ink, because
# the deck's ground is dark. A figure saved with a white background sits
# in a glaring pale box on the slide, which is the exact problem the dark
# palette exists to avoid.
import csv
import io
import os
import statistics as st

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt                      # noqa: E402
from matplotlib.patches import (FancyBboxPatch, Rectangle,              # noqa: E402
                                FancyArrowPatch, Circle)

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'assets')
CSV = os.path.join(os.path.dirname(HERE), 'Hops User Testing Part 1.csv')
DPI = 220

# Hops Default, inverted for a dark room — see build_deck.py's palette note.
TEXT = "#E2FFFE"
SOFT = "#9CC8CC"
FAINT = "#6E9BA0"
TEAL = "#5FD3D8"
ACCENT = "#FF8A5C"
GOLD = "#C9A227"
PANEL = "#0A353C"
PANEL_2 = "#123F47"
RULE = "#1C5059"
FS = "DejaVu Sans"


def fig(w, h, ymax=100):
    f, ax = plt.subplots(figsize=(w, h))
    ax.set_xlim(0, 100)
    ax.set_ylim(0, ymax)
    ax.axis("off")
    f.patch.set_alpha(0)
    ax.patch.set_alpha(0)
    return f, ax


def save(f, name):
    f.savefig(os.path.join(OUT, name), dpi=DPI, bbox_inches="tight",
              transparent=True, pad_inches=0.05)
    plt.close(f)
    print("  ", name)


def txt(ax, x, y, s, size=9, color=TEXT, ha="center", va="center",
        weight="normal", style="normal"):
    ax.text(x, y, s, ha=ha, va=va, fontsize=size, color=color,
            family=FS, weight=weight, style=style)


def panel(ax, x, y, w, h, fc=PANEL, ec=RULE, lw=1.2, r=1.4):
    ax.add_patch(FancyBboxPatch((x, y), w, h,
                                boxstyle="round,pad=0.3,rounding_size=%s" % r,
                                facecolor=fc, edgecolor=ec, linewidth=lw))


def arrow(ax, p1, p2, color=TEAL, lw=1.6, style="-|>", mut=14, ls="-"):
    ax.add_patch(FancyArrowPatch(p1, p2, arrowstyle=style, color=color,
                                 linewidth=lw, linestyle=ls,
                                 mutation_scale=mut, shrinkA=3, shrinkB=3))


def phone(ax, cx, cy, w=9, h=15, fc=PANEL_2, ec=TEAL, lw=1.6):
    ax.add_patch(FancyBboxPatch((cx - w / 2, cy - h / 2), w, h,
                                boxstyle="round,pad=0.2,rounding_size=1.6",
                                facecolor=fc, edgecolor=ec, linewidth=lw))
    ax.plot([cx - w * 0.18, cx + w * 0.18],
            [cy + h / 2 - 1.3, cy + h / 2 - 1.3],
            color=ec, lw=1.2, solid_capstyle="round")


# ── d_packet: the 24-character advertisement name ─────────────────────
def f_packet():
    f, ax = fig(9.6, 3.4)
    fields = [("CM:", 3, ACCENT), ("who sent it", 8, TEAL), ("#", 1, GOLD),
              ("of", 1, GOLD), ("the message text", 11, "#6FAF8C")]
    x, unit = 3.0, 94.0 / 24.0
    for name, n, col in fields:
        w = unit * n
        ax.add_patch(Rectangle((x, 44), w, 26, facecolor=PANEL,
                               edgecolor=RULE, linewidth=1.2))
        ax.add_patch(Rectangle((x, 66), w, 4, facecolor=col, edgecolor="none"))
        txt(ax, x + w / 2, 57, name, size=8.6, weight="bold")
        txt(ax, x + w / 2, 49, str(n), size=7.6, color=SOFT)
        x += w
    for i in range(25):
        gx = 3.0 + unit * i
        ax.plot([gx, gx], [40.5, 43], color=RULE, lw=0.7)
    txt(ax, 3.0, 37, "1", size=6.4, color=FAINT)
    txt(ax, 97.0, 37, "24", size=6.4, color=FAINT)
    ax.annotate("", xy=(3, 30), xytext=(97, 30),
                arrowprops=dict(arrowstyle="<|-|>", color=SOFT, lw=1.2,
                                mutation_scale=12))
    txt(ax, 50, 24.5, "24 characters. That is the whole protocol.",
        size=9.5, weight="bold")
    txt(ax, 50, 15,
        "13 are labels  →  11 left for what you actually wrote\n"
        "longer messages split across up to 8 of these and reassemble on "
        "the other side", size=7.8, color=SOFT)
    txt(ax, 50, 78, "One Bluetooth broadcast", size=11, color=TEAL, weight="bold")
    save(f, "d_packet.png")


# ── d_mesh: relay beyond one phone's range ────────────────────────────
def f_mesh():
    f, ax = fig(9.6, 4.0)
    ys, xs = 52, [14, 38, 62, 86]
    labels = ["You", "Someone\nnearby", "Someone\nnear them", "…and on"]
    for x in xs[:-1]:
        for rr, al in ((13, 0.20), (9.5, 0.30)):
            ax.add_patch(Circle((x, ys), rr, facecolor="none", edgecolor=TEAL,
                                lw=1.0, alpha=al, ls=(0, (3, 3))))
    for i, (x, lab) in enumerate(zip(xs, labels)):
        phone(ax, x, ys, ec=ACCENT if i == 0 else TEAL,
              fc="#2A1410" if i == 0 else PANEL_2)
        txt(ax, x, ys - 13.5, lab, size=8,
            color=TEXT if i == 0 else SOFT,
            weight="bold" if i == 0 else "normal")
    for i in range(3):
        arrow(ax, (xs[i] + 5.5, ys), (xs[i + 1] - 5.5, ys), color=ACCENT, lw=2.0)
        txt(ax, (xs[i] + xs[i + 1]) / 2, ys + 7.5, "passes it on",
            size=7, color=ACCENT)
    txt(ax, 50, 88, "An alert travels further than any one phone can reach",
        size=11.5, weight="bold")
    txt(ax, 50, 80, "every phone that hears it repeats it", size=8.5, color=SOFT)
    txt(ax, 50, 18, "Range is set by how many Hops phones are in the chain — "
                    "not by any one radio.", size=8, color=FAINT, style="italic")
    save(f, "d_mesh.png")


# ── d_radios: three jobs, three mechanisms ────────────────────────────
def f_radios():
    f, ax = fig(9.6, 3.9)
    cards = [
        (3, "A megaphone", "one shout,\neveryone hears", ACCENT,
         "who's nearby · emergency flares\nalerts · requests · crowd reports"),
        (35.3, "A phone call", "one to one,\nback and forth", TEAL,
         "actual 1:1 chats\nprofile pictures and bios"),
        (67.6, "A courier", "one to one,\nbulk transfer", "#9D8BD8",
         "Hops Share only:\nfiles and quick notes"),
    ]
    for x, title, kind, col, carries in cards:
        panel(ax, x, 10, 29.4, 74)
        ax.add_patch(Rectangle((x, 78), 29.4, 5, facecolor=col, edgecolor="none"))
        txt(ax, x + 14.7, 68, title, size=12, weight="bold")
        txt(ax, x + 14.7, 56, kind, size=8, color=col, style="italic")
        txt(ax, x + 14.7, 36, carries, size=7.8, color=SOFT)
    txt(ax, 50, 96, "Three different jobs, three different mechanisms",
        size=11, weight="bold")
    save(f, "d_radios.png")


# ── d_rotate: the identity that changes every 15 minutes ──────────────
def f_rotate():
    f, ax = fig(9.6, 3.2)
    y = 52
    ax.plot([6, 94], [y, y], color=RULE, lw=1.4)
    for i, c in enumerate(["7kQ2mXp4", "a9Lz0Rt6", "Bv3nH8wE", "xS5dK1jY"]):
        x = 15 + i * 23.5
        ax.plot([x, x], [y - 3, y + 3], color=TEAL, lw=1.4)
        panel(ax, x - 9.5, y + 7, 19, 13, fc=PANEL_2, ec=TEAL)
        txt(ax, x, y + 13.5, c, size=9, color=TEAL, weight="bold")
        txt(ax, x, y - 8, "%d min" % (i * 15), size=7.4, color=FAINT)
        if i < 3:
            arrow(ax, (x + 10, y + 13.5), (x + 14, y + 13.5),
                  color=FAINT, lw=1.1, mut=9)
    txt(ax, 50, 90, "Your phone changes disguise four times an hour",
        size=11.5, weight="bold")
    txt(ax, 50, 81, "the broadcast carries a code, never your name",
        size=8.5, color=SOFT)
    txt(ax, 50, 24, "Only someone you've already chatted with can tell these "
                    "are the same phone.", size=8, color=SOFT)
    txt(ax, 50, 14, "Anyone else with a scanner sees a meaningless string "
                    "that is stale within the quarter hour.",
        size=7.6, color=FAINT, style="italic")
    save(f, "d_rotate.png")


# ── d_noserver: how a normal app does it, and how Hops does ───────────
def f_noserver():
    f, ax = fig(9.6, 3.6)
    txt(ax, 25, 93, "How a normal app does it", size=9.5, color=FAINT, weight="bold")
    panel(ax, 17, 62, 16, 13, fc=PANEL, ec=FAINT)
    txt(ax, 25, 68.5, "server", size=8, color=FAINT)
    phone(ax, 12, 28, w=8, h=13, ec=FAINT, fc=PANEL)
    phone(ax, 38, 28, w=8, h=13, ec=FAINT, fc=PANEL)
    arrow(ax, (14, 34), (21, 61), color=FAINT, lw=1.3, style="-")
    arrow(ax, (36, 34), (29, 61), color=FAINT, lw=1.3, style="-")
    txt(ax, 25, 14, "every message goes up and back down", size=7.4, color=FAINT)
    ax.plot([50, 50], [8, 86], color=RULE, lw=1.0, ls=(0, (4, 4)))
    txt(ax, 75, 93, "How Hops does it", size=9.5, color=TEAL, weight="bold")
    phone(ax, 62, 42, w=9, h=15, ec=TEAL, fc=PANEL_2)
    phone(ax, 88, 42, w=9, h=15, ec=TEAL, fc=PANEL_2)
    arrow(ax, (67, 42), (83, 42), color=ACCENT, lw=2.2, style="<|-|>")
    txt(ax, 75, 50, "straight to each other", size=7.8, color=ACCENT)
    txt(ax, 75, 25, "no server on the path at all", size=8.2, weight="bold")
    txt(ax, 75, 16, "we do have one — it only holds who you are,\n"
                    "and no message ever touches it", size=7.2, color=SOFT)
    save(f, "d_noserver.png")


# ── d_pyramid: the testing layers, as actually built ──────────────────
def f_pyramid():
    f, ax = fig(9.6, 3.6)
    bands = [
        (68, 24, "Two real phones, by hand", ACCENT,
         "The ONLY way to test BLE, RFCOMM and Nearby.\n"
         "Every peer-to-peer feature, every time."),
        (38, 24, "Widget tests — 10", GOLD,
         "One widget under test: the password strength meter."),
        (8, 24, "Unit tests — 115", TEAL,
         "Wire format 57 · credential rules 27 · currency 13\n"
         "name guard 8 · accessibility 7 · flare radio 3"),
    ]
    for y, h, title, col, sub in bands:
        ax.add_patch(Rectangle((4, y), 2.6, h, facecolor=col, edgecolor="none"))
        panel(ax, 6.6, y, 89, h)
        txt(ax, 10, y + h * 0.66, title, size=11, weight="bold", ha="left")
        txt(ax, 10, y + h * 0.26, sub, size=7.6, color=SOFT, ha="left")
    txt(ax, 50, 1.5, "125 automated tests sit under a layer that cannot be "
                     "automated at all.", size=8, color=FAINT, style="italic")
    save(f, "d_pyramid.png")


# ── d_survey: computed from the acceptance study, never typed in ──────
def f_survey():
    rows = list(csv.reader(io.open(CSV, encoding="utf-8-sig")))
    data = rows[1:]
    groups = [("Sign-up & sign-in", 14, 17), ("Features", 52, 58),
              ("Themes & colour", 29, 32), ("Look & feel", 59, 63),
              ("Walkthrough", 48, 51), ("Watch Me", 37, 39),
              ("Emergency Flare", 33, 36), ("Radar", 22, 24),
              ("Hops Share", 44, 45)]
    vals = []
    for name, a, b in groups:
        v = [int(r[i]) for r in data for i in range(a, b + 1)
             if i < len(r) and r[i].strip().isdigit()]
        vals.append((st.mean(v), name))
    vals.sort()

    f, ax = plt.subplots(figsize=(9.6, 3.8))
    f.patch.set_alpha(0)
    ax.patch.set_alpha(0)
    y = range(len(vals))
    cols = [ACCENT if m < 4.4 else (TEAL if m > 4.6 else GOLD) for m, _ in vals]
    ax.barh(list(y), [m for m, _ in vals], color=cols, height=0.62, zorder=3)
    ax.set_yticks(list(y))
    ax.set_yticklabels([n for _, n in vals], fontsize=9, color=TEXT, family=FS)
    ax.set_xlim(3.8, 5.0)
    ax.tick_params(axis="x", labelsize=8, colors=SOFT)
    ax.tick_params(axis="y", colors=TEXT, length=0)
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.spines["bottom"].set_color(RULE)
    ax.grid(axis="x", color=RULE, lw=0.7, zorder=0)
    for i, (m, _) in enumerate(vals):
        ax.text(m + 0.015, i, "%.2f" % m, va="center", fontsize=8.4,
                color=TEXT, family=FS, weight="bold")
    ax.set_xlabel("Mean rating out of 5, from %d students" % len(data),
                  fontsize=8.5, color=SOFT, family=FS)
    save(f, "d_survey.png")


if __name__ == "__main__":
    print("deck figures ->", OUT)
    f_packet()
    f_mesh()
    f_radios()
    f_rotate()
    f_noserver()
    f_pyramid()
    f_survey()
    print("done")

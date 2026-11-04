# Content for the Group 18 presentation practice pack.
#
# Data only — build_pack.py owns the page setup and styles.
# Extracted from the committed .docx so the generator
# reproduces it exactly. Blocks are in document order;
# "t" is "p" for a paragraph or "table" for a table.

BLOCKS = [
    {"t": "p", "style": 'Title', "runs": [
        {"text": 'Presentation Practice Pack'},
    ]},
    {"t": "p", "style": 'Normal', "after": 2.0, "runs": [
        {"text": 'Hops — Group 18 — IT Project', "size": 14.0, "color": '46555A'},
    ]},
    {"t": "p", "style": 'Normal', "after": 20.0, "runs": [
        {"text": 'Companion to “Group 18 Presentation.pptx”. Every figure in here is counted from the repository, not estimated.', "italic": True, "size": 10.0, "color": '46555A'},
    ]},
    {"t": "p", "style": 'Normal', "after": 8.0, "runs": [
        {"text": 'How to use this pack.  ', "bold": True, "size": 11.0},
        {"text": 'Print it, or print only your own pages — section 3 gives each person their own page. Read section 2 before the first rehearsal; it is the shared discipline that makes seven presenters look like one team rather than seven. Section 4 is the question bank: everybody should be able to answer the first four, and the person named on each of the others owns it.', "size": 11.0},
    ]},
    {"t": "p", "style": 'Normal', "after": 16.0, "runs": [
        {"text": 'Before the day.  ', "bold": True, "size": 11.0},
        {"text": 'Section 5 is a pre-flight checklist. Somebody has to own it — agree who, now. Section 6 is what to say when a live demo fails, which is the single most likely thing to go wrong in this hour.', "size": 11.0},
    ]},
    {"t": "p", "style": 'Heading 1', "after": 6.0, "before": 12.0, "runs": [
        {"text": '1.  How the hour runs'},
    ]},
    {"t": "p", "style": 'Normal', "after": 8.0, "runs": [
        {"text": 'Seven presenters, fourteen segments, round-robin. Each person speaks twice: once in round one to explain something, once in round two to show that same thing running. The pairing is deliberate — you demonstrate what you explained, so you are never presenting someone else’s work.', "size": 11.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Round one — the narrative  (~18 minutes)'},
    ]},
    {"t": "table", "widths": [0.4, 1.0, 3.9, 0.9], "rows": [
        ['#', 'Who', 'Topic', 'Time'],
        ['1', 'Victor', 'The problem: every campus safety app assumes the internet works', '2½ min'],
        ['2', 'Hlonipha', 'What it had to do, and how we found out', '3½ min'],
        ['3', 'Sade', 'The app a student actually opens', '2½ min'],
        ['4', 'Thrishen', 'No server in the middle; three radios, three jobs', '2¾ min'],
        ['5', 'Elijah', 'The whole protocol fits in 24 bytes; where data lives', '4¼ min'],
        ['6', 'Nabihah', 'Emergency Flare, and why it has no button', '4¼ min'],
        ['7', 'Jocelyn', 'Signatures, rotating identities, and what we have not solved', '4 min'],
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Round two — live software and depth  (~21 minutes)'},
    ]},
    {"t": "table", "widths": [0.4, 1.0, 3.9, 0.9], "rows": [
        ['#', 'Who', 'Topic', 'Time'],
        ['8', 'Victor', 'LIVE — first run, sign-up, and the radar', '3 min'],
        ['9', 'Hlonipha', 'What thirteen students told us, and the three things we got wrong', '2¾ min'],
        ['10', 'Sade', 'LIVE — the everyday features, including airplane mode', '3 min'],
        ['11', 'Thrishen', 'LIVE — friend request, 1:1 chat, community alerts', '3 min'],
        ['12', 'Elijah', 'The backend lockdown, and a live offline database restore', '3 min'],
        ['13', 'Nabihah', 'LIVE — Emergency Flare on two devices, and an official alert', '4 min'],
        ['14', 'Jocelyn', 'How we know it works; limits; what we would do next; close', '2½ min'],
    ]},
    {"t": "p", "style": 'Normal', "after": 8.0, "runs": [
        {"text": 'Then roughly twenty minutes of questions.  ', "bold": True, "size": 11.0},
        {"text": 'That is deliberate and we should say so from the first slide. A group that wants questions reads as a group that knows its own work.', "size": 11.0},
    ]},
    {"t": "p", "style": 'Heading 1', "after": 6.0, "before": 12.0, "brk": True, "runs": [
        {"text": '2.  Rules for the room'},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Handovers'},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Always', "bold": True, "size": 10.0},
        {"text": '  name who is next before you stop talking — “Thrishen is going to show you why there is no server in the middle.” Then physically swap position.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Never', "bold": True, "size": 10.0},
        {"text": '  read the divider slides aloud. They exist to give you a clean moment to swap.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Never', "bold": True, "size": 10.0},
        {"text": '  recap what the last person said. It burns time and it sounds like you did not trust them.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'While someone else is presenting'},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Stand to the side, face the speaker, and do not look at your phone — even to check the demo device. Nominate one person to babysit the phones.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'If a teammate stalls, do not rescue them mid-sentence. Give them five seconds. Only step in if they explicitly look at you.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Questions'},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Everyone comes to the front for the question period. It reads as a team.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Jocelyn fields and routes: “that’s Elijah’s area.” Do not answer a question outside your segment unless routed to.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Three seconds of thinking before answering is fine and looks confident. Filling it with “um, so, basically” does not.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Things never to say'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": '“I don’t know.”  ', "bold": True, "size": 11.0, "color": 'B23A1E'},
        {"text": 'Say instead: “we haven’t tested that — here’s what we do know.” Then give the adjacent fact you do have. There is a difference between an untested claim and an unknown one, and judges can tell.', "size": 11.0},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": '“It should work.”  ', "bold": True, "size": 11.0, "color": 'B23A1E'},
        {"text": 'Either it is verified on hardware or it is not. If a demo fails, say what failed and why — section 6 has the wording.', "size": 11.0},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": 'Any number not in section 7.  ', "bold": True, "size": 11.0, "color": 'B23A1E'},
        {"text": 'If you are not certain of a figure, describe it instead: “a few dozen metres”, not a number you half-remember. One wrong number invites a judge to check the rest.', "size": 11.0},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": '“It’s basically like AirDrop / WhatsApp.”  ', "bold": True, "size": 11.0, "color": 'B23A1E'},
        {"text": 'Comparisons invite the question “so why not just use that?” Describe what it does instead.', "size": 11.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Pace'},
    ]},
    {"t": "p", "style": 'Normal', "after": 8.0, "runs": [
        {"text": 'The whole deck is 33 slides for roughly 39 minutes of speaking — a little over a minute a slide. If you are running long, cut detail from round one, never from round two. The live software is what earns the marks and it is at the back.', "size": 11.0},
    ]},
    {"t": "p", "style": 'Heading 1', "after": 6.0, "before": 12.0, "brk": True, "runs": [
        {"text": '3.  Your pages'},
    ]},
    {"t": "p", "style": 'Normal', "after": 8.0, "runs": [
        {"text": 'Find your name. These are the two segments you own, what to hit in each, and the questions most likely to come to you.', "italic": True, "size": 11.0, "color": '46555A'},
    ]},
    {"t": "p", "style": 'Heading 1', "after": 6.0, "before": 12.0, "runs": [
        {"text": 'Victor'},
    ]},
    {"t": "p", "style": 'Normal', "after": 12.0, "runs": [
        {"text": 'Project Manager · Business/System Analyst · Frontend · Backend · Database', "italic": True, "size": 10.0, "color": '46555A'},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Segment 1 — The problem (2½ min, 2 slides)'},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Open the whole presentation. Keep it to two sentences before the content starts.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'The thesis: every campus safety app has a buried assumption that the phone has working internet — and that assumption fails exactly when it matters.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Give ONE scenario, not three. The basement corridor with no signal is the best: everyone in the room has been somewhere on campus with no bars.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Then the pivot: every phone already has a Bluetooth radio, it costs nothing to use, and on campus it is sitting idle being used to pair headphones.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Slide 2 is the pitch sentence. Say it once, slowly, then stop and let it sit.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": 'Watch out.  ', "bold": True, "size": 10.0, "color": 'B23A1E'},
        {"text": 'Do not cite campus crime statistics we cannot source. Stay on the technical gap — that is the argument we can actually defend.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Segment 8 — LIVE — first run and the radar (3 min)'},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'This is the first live moment of the hour; it sets expectations for all of round two.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Install is a single APK: no store, no provisioning, no server address to configure.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Sign up on device A and point out the key-generation step — that keypair is being made on the phone and the private half never leaves it.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Land on the radar. Device B appears as a dot within a few seconds.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Point at the dot: “that is my teammate’s phone, and it does not say so. That is deliberate.”', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": 'Watch out.  ', "bold": True, "size": 10.0, "color": 'B23A1E'},
        {"text": 'Narrate every tap. The audience is watching a mirrored phone screen and will lose you otherwise. Rehearse until it is boring.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Questions most likely to come to you'},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": 'Who would actually install this?', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'Two answers, and give both. First, the everyday features — crowd levels, watch-me, file sharing — are the reason it stays installed. Second, that is the point: an app nobody opens is not running on the day it matters.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": 'Isn’t this just a worse version of an existing app?', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'Every alternative needs a working connection on the phone of the person in trouble. Hops needs two phones and nothing else. That is not a smaller version of the same thing, it is a different assumption.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": 'How long did this take you?', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'A semester, seven people, roughly 37,000 lines of Dart in the app itself. Do not inflate it.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 1', "after": 6.0, "before": 12.0, "brk": True, "runs": [
        {"text": 'Hlonipha'},
    ]},
    {"t": "p", "style": 'Normal', "after": 12.0, "runs": [
        {"text": 'Business/System Analyst', "italic": True, "size": 10.0, "color": '46555A'},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Segment 2 — Requirements, and how we found them (3½ min, 2 slides)'},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'This segment exists to prove the requirements were not invented at a table.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Method first: we are the users — seven students on this campus — plus a structured study of thirteen students run face to face by five of us.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Use the word “hesitated”. Watching where people hesitated is what a questionnaire alone would have missed, and it signals real usability work.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Then the four requirements that shaped everything: works with no connection at all; an alert must outrun one phone’s range; it must not become a tracking device; a stranger’s alert must be verifiable offline.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Say out loud that each one maps to a later segment — Thrishen answers the first two, Jocelyn the last two. It makes the hour feel designed.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": 'Watch out.  ', "bold": True, "size": 10.0, "color": 'B23A1E'},
        {"text": 'Do NOT give findings here. That is segment 9 and repeating it wastes both slots. Here you only establish the method.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Segment 9 — What thirteen students told us (2¾ min, 2 slides)'},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": "Lead with the honestly good numbers — a mean of 4.57 out of 5 across 54 items, and 12 of 13 saying they would use it regularly — then spend most of the time on what they disliked. That ordering makes the praise believable. Say '12 of 13', never '100%': one answered 'maybe'.", "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Three real failures: the Bluetooth density indicator did not explain itself (our lowest-scoring item at 3.92), nobody could find Received Files, and — the one that matters — Emergency Flare came third-lowest of fourteen areas, with only 4.15 on whether people understood that a flare alerts those around them.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Quote “it’s ugly” out loud with a straight face. It is real data, it gets a laugh, and it buys enormous credibility for everything else we claim.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Close on what changed: the most common request was a proper dark mode and more colour, and there is now a theme catalogue as a direct result.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": 'Watch out.  ', "bold": True, "size": 10.0, "color": 'B23A1E'},
        {"text": 'Do NOT claim the two discoverability problems are fixed. They are not — they are in Jocelyn’s future-scope slide, and claiming otherwise is the kind of thing a judge checks.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Questions most likely to come to you'},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": 'Thirteen is a small sample.', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'Agree immediately. “Thirteen is small. We treated it as qualitative, and it still found three things we had got wrong.” Do not defend it as statistically significant — owning it costs nothing and arguing costs a lot.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": 'How did you avoid leading the participants?', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'Rated items were fixed and identical for everyone, and the free-text questions came last so the rating scale did not prime them. Five different people ran sessions, which spreads out any one person’s bias.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": 'Did you test with anyone who isn’t an IT student?', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'Honestly: the sample skews toward IT students, which is a real limitation of the study. A second round with a wider sample is on the future-scope list.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 1', "after": 6.0, "before": 12.0, "brk": True, "runs": [
        {"text": 'Sade'},
    ]},
    {"t": "p", "style": 'Normal', "after": 12.0, "runs": [
        {"text": 'UI/UX Designer · Frontend Developer', "italic": True, "size": 10.0, "color": '46555A'},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Segment 3 — The app a student opens (2½ min, 2 slides)'},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'You own the interface — speak about the decisions, not just the layout.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Five tabs, and the first is a radar, because “who is around me” is the question the whole app answers.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Lead with the opt-in catalogue: eight optional mini-apps, a user adds what they want, the rest stay out of the way. It is a genuine answer to feature bloat.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Drop the hook — the safety feature has no button — and do NOT explain it. That hands Nabihah a warm room three segments later.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'The numbers slide is 30 seconds. Point at “2 apps from one codebase” and explain it in one line: same APK, two entry points, different front door.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": 'Watch out.  ', "bold": True, "size": 10.0, "color": 'B23A1E'},
        {"text": 'Resist walking through all eight features here. You demo them in segment 10 and doing it twice wastes your best slot.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Segment 10 — LIVE — the everyday features (3 min)'},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Add Vibe Check from the catalogue on camera, so the opt-in point lands visually.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Tag the room’s crowd level on A; it appears on B with no account link between the devices.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Study Bunny Finder: broadcast a module code on A, find it on B. Say that it carries no sender identity at all — it reinforces Jocelyn’s privacy segment.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Lost & Found relays hop-to-hop like a flare, so it travels past direct range.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Then airplane mode. Turn it on in front of the room, hold the phone up so the icon is visible, and use the app.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": 'Watch out.  ', "bold": True, "size": 10.0, "color": 'B23A1E'},
        {"text": 'Five features in three minutes is tight. Pick the three that work most reliably on the day — a clean three beats a rushed five. The airplane-mode moment is the most persuasive thing in the whole hour; do not rush it.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Questions most likely to come to you'},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": 'Why is the app so plain-looking?', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'Own it — the user study said the same thing and it was our lowest-scoring cluster. Then the answer: we spent the time on the radio layer and the safety path first, and the theme catalogue was the first thing we added when testing told us to.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": 'Why make features opt-in instead of just shipping them all?', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'Because a safety app you cannot navigate in a hurry is a failed safety app. Eight features on one screen buries the two that matter.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": 'What happens if a user adds nothing?', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'Radar, contacts, chat, community alerts and the flare are always present — they are not in the catalogue. The catalogue is only the optional extras.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 1', "after": 6.0, "before": 12.0, "brk": True, "runs": [
        {"text": 'Thrishen'},
    ]},
    {"t": "p", "style": 'Normal', "after": 12.0, "runs": [
        {"text": 'UI/UX Designer · Backend Developer', "italic": True, "size": 10.0, "color": '46555A'},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Segment 4 — No server in the middle; three radios (2¾ min, 2 slides)'},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'State the claim flatly: there is no server in the middle. Your messages, tasks, crowd reports and alerts never reach one.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Then immediately concede the exception yourself, before anyone extracts it: we do have a backend, but it only holds who you are and the moderation records.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Conceding it yourself is what makes the claim credible. If a judge pulls it out of you it sounds like you were overselling.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Then the three mechanisms: BLE broadcast for the mesh, classic Bluetooth RFCOMM for real 1:1 chat, Nearby Connections for file transfer.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Being able to say which does what is the clearest on-stage proof that we understand our own system.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": 'Watch out.  ', "bold": True, "size": 10.0, "color": 'B23A1E'},
        {"text": 'Learn the “why not just one?” answer verbatim — it is the single best question you can be asked. See the question bank below.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Segment 11 — LIVE — chat and the second radio (3 min)'},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Refer back explicitly: “the friend request was mechanism one, this chat is mechanism two.”', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Friend request from A to B is a BLE broadcast, not a server call. Accept on B.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Open a chat and send a message — this is the RFCOMM socket, a real connection.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Show the avatar and bio appearing on the other side: that is the profile exchange over the same socket, and it is the only way cosmetics cross devices.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Then a long community alert, so the audience sees Elijah’s 24-byte budget being chunked and reassembled.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": 'Watch out.  ', "bold": True, "size": 10.0, "color": 'B23A1E'},
        {"text": 'KNOWN RISK: this is our least reliable demo. Classic Bluetooth connection can hang on some stacks, and a presentation room is a crowded radio environment. Have it already connected before you start if you can — reconnecting live is the risky part, not sending the message.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Questions most likely to come to you'},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": 'Why not just use one mechanism for everything?', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'Learn this one: the three jobs have incompatible shapes — broadcast-to-everyone, reliable-stream-to-one, and bulk-file-to-one. Forcing them down one mechanism means either a chat that cannot hold a sentence, or an alert that has to connect to each phone in turn — and connecting takes seconds per device, which an emergency does not have.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": 'Doesn’t running three Bluetooth systems drain the battery?', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'They do not all run at once. Nearby Connections only runs inside the file-sharing screen, and entering it pauses the mesh because both compete for the same radio. The idle state is a low-power broadcast and a scan.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": 'Why is identity online if nothing else is?', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'Because a key directory has to come from somewhere once. After that first sync a device can verify a stranger’s alert offline forever — the network is needed to learn keys, not to use them.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 1', "after": 6.0, "before": 12.0, "brk": True, "runs": [
        {"text": 'Elijah'},
    ]},
    {"t": "p", "style": 'Normal', "after": 12.0, "runs": [
        {"text": 'Database Developer', "italic": True, "size": 10.0, "color": '46555A'},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Segment 5 — 24 bytes, and where data lives (4¼ min, 3 slides)'},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'This is the most distinctive engineering in the project. Give it room.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Open with the absurdity of the number: the entire protocol for this app fits in twenty-four bytes — shorter than that sentence.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'A Bluetooth advertisement is capped at 31 bytes; headers and our service identifier eat most of it; 26 remain; we budget 24 for margin.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'The detail that proves hardware experience: an over-long name does not get truncated, the whole advertisement is rejected and the message silently never leaves the phone.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Walk the byte diagram left to right, then land the consequence: 13 bytes of overhead leave 11 for text, so a message splits across up to 8 chunks — 88 bytes per broadcast.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Then the hard-won detail: a split must never land in the middle of a multi-byte character, and there is a test for exactly that.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Third slide is where data lives — 40 seconds. End on: the strongest privacy guarantee we have is that most of this data is not on a server to leak.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": 'Watch out.  ', "bold": True, "size": 10.0, "color": 'B23A1E'},
        {"text": 'If asked where signatures fit — they do not. They ride a second parallel field on the same packet, 18 bytes at a time. Hand that to Nabihah and Jocelyn.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Segment 12 — The backend, and a live restore (3 min, 2 slides)'},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": '“Zero policies” sounds like a mistake until you explain it — so explain it in the same breath: row-level security with no policies means deny-all. Nothing is read or written directly.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Everything goes through 65 narrow functions, each validating its own inputs, with 74 permission revocations and 61 explicit grants defining exactly what a client may call.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Then the restore demo, with the line ready: “an untested backup isn’t a backup.”', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Run the verification script. It needs no network at all, which is why you can run it in the room with the wifi off.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'It restores the latest dump into a local scratch database and counts what came back — last verified run was 8 of 8 tables and 67 of 67 rows.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": 'Watch out.  ', "bold": True, "size": 10.0, "color": 'B23A1E'},
        {"text": 'PRE-FLIGHT: confirm the local PostgreSQL service is running and that you know the local password. Do a full dry run the morning of. There is a runbook: docs/backup-demo-runbook.md.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Questions most likely to come to you'},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": 'Why write 65 functions instead of just using table permissions?', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'Because a permission says who may touch a table; a function says what may be done to it. Deny-all plus narrow functions means a compromised client can only do the specific operations we wrote, with the validation we wrote, and nothing else.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": 'How are the backups stored, and is the dump sensitive?', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'Very — it holds every row in the cloud database including password hashes and the whole moderation log. The backup folder is gitignored deliberately as a folder, not a file pattern, so it can never be committed by accident.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": 'How do you handle the database connection password?', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'The script reads the connection string from a prompt, never as a command-line argument, because PowerShell writes every typed command to a history file in plaintext permanently. There is also a masked mode for exactly this situation — presenting on a projector.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 1', "after": 6.0, "before": 12.0, "brk": True, "runs": [
        {"text": 'Nabihah'},
    ]},
    {"t": "p", "style": 'Normal', "after": 12.0, "runs": [
        {"text": 'Documentation Manager', "italic": True, "size": 10.0, "color": '46555A'},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Segment 6 — Emergency Flare (4¼ min, 3 slides)'},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Slow down. This is the emotional centre of the presentation and rushing it undercuts everything else.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'One press with confirmation; the flare broadcasts who you are and a short reason and stays live for sixty seconds.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Sixty, not thirty — and the reason is good evidence of real testing: thirty closed the window while someone was still working out where the sound was coming from.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Every phone that hears it passes it on and sounds an alarm. That relay is the mesh doing its job, on devices whose owners you have never met.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Then the removal story: we built a volume-button gesture and took it out, because manufacturer skins intercept volume keys and it silently did nothing on some handsets. Land it as a principle — a safety feature that works sometimes is worse than none, because it teaches a gesture the user then trusts.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Third slide, 45 seconds: two people flaring at once. Each of the four invariants cost a real bug.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": 'Watch out.  ', "bold": True, "size": 10.0, "color": 'B23A1E'},
        {"text": 'Do NOT trigger a flare in this segment. It is demonstrated properly in segment 13, with a warning to the room first.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Segment 13 — LIVE — flare on two devices, and an official alert (4 min, 2 slides)'},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'WARN THE ROOM FIRST. “There’s going to be an alarm in about twenty seconds, and it’s designed to be impossible to ignore.” An unannounced siren costs real goodwill.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Put both phones in airplane mode, visibly, with Bluetooth on. That is what makes this undeniable.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Trigger from the Quick Settings tile — not from inside the app, because there is no button. Confirm, pick a reason.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Device B alarms within seconds showing sender and reason. Point at the verified marker: that signature was checked with no network. That is the payoff of Jocelyn’s segment 7.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Stand down from A, show B’s alarm stop, and note it would have expired on its own anyway.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Then 60 seconds on the admin app: same APK, second entry point, compose a campus-wide alert.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": 'Watch out.  ', "bold": True, "size": 10.0, "color": 'B23A1E'},
        {"text": 'PRE-FLIGHT: confirm device A can actually advertise. Some handsets receive but cannot transmit, and the app will correctly refuse the flare — that is right behaviour, not a crash. Test with the ACTUAL phone you will use and keep a screen recording as backup. Admin sign-in does need the network; be upfront about it.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Questions most likely to come to you'},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": 'What stops someone sending a fake emergency?', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'Flares are signed with a private key that never leaves the device, and receivers verify against a cached public key directory, offline. An unverified flare is shown as unverified. Beyond that it is a moderation problem, and there is a report-and-ban path with an audit log.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": 'What if someone just spams flares?', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'Each one is attributable to a real account, and an admin can ban that account. We do not have an automated rate limit on the radio itself — that is an honest gap and worth saying.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": 'Why can’t I trigger it from inside the app?', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'Because a screen you have to unlock, open and navigate is not reachable in the situation this exists for. The Quick Settings tile works from the lock screen.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": 'What if nobody with the app is nearby?', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'Then nothing happens, and we should say so plainly. Hops is a network effect — it is useful in proportion to how many people on campus have it, and it is not a replacement for calling emergency services when you have signal.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 1', "after": 6.0, "before": 12.0, "brk": True, "runs": [
        {"text": 'Jocelyn'},
    ]},
    {"t": "p", "style": 'Normal', "after": 12.0, "runs": [
        {"text": 'Documentation Manager', "italic": True, "size": 10.0, "color": '46555A'},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Segment 7 — Signatures, rotation, and what we have not solved (4 min, 3 slides)'},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'The offline-verification point is the cleverest thing in the project. Make it land: the phone receiving an alert does not need the internet to check it, because it already has the public keys cached.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'A keypair is generated on the phone at sign-up; the public half goes to the backend, the private half into the secure store, never transmitted again.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'BE PRECISE and volunteer the limit: only flares and official alerts are signed. The rest of the mesh is not, because signatures do not fit in 24 bytes and we spent them where forgery causes harm. Say it before a judge finds it.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Second slide: set up the tracking threat concretely — anyone with a free scanner app could sit in a corridor and reconstruct who walked past, so a fixed username would make this a surveillance tool. Hence the rotating token, derived from a secret seed and a 15-minute window. Naming the Apple/Google exposure-notification precedent is worth saying.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Third slide is the unsolved limitation. Do not skip it.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": 'Watch out.  ', "bold": True, "size": 10.0, "color": 'B23A1E'},
        {"text": 'Deliver the limitation as a known, bounded problem with a known fix — not as an apology. “This is the thing we would fix first, and we know exactly what it would take.”', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Segment 14 — Testing, limits, future scope, close (2½ min, 2 slides)'},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Precision beats a big number. 125 automated tests, 57 of which pin the wire format alone.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Volunteer the gap before you are asked: nothing about the radios is automated and nothing can be — BLE, RFCOMM and Nearby need two physical devices in a room. Everything in round two was verified by hand, repeatedly.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Also volunteer that the local database layer is untested, and that it is the obvious next target.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Future scope — four items, each traceable to something earlier in the hour. Say that: “every one of these came out of the last forty minutes.”', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Close briefly: “We set out to build something that works when the network doesn’t. It does — you’ve watched it run in airplane mode. Thank you. We’d like to take questions.”', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Then everyone comes to the front.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": 'Watch out.  ', "bold": True, "size": 10.0, "color": 'B23A1E'},
        {"text": 'You also route questions — see the owners table in section 4.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Questions most likely to come to you'},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": 'What’s the weakest part of the system?', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'Two things, and saying them is better than being caught by them. The Bluetooth name exposure, which needs payloads moved off the advertisement name to fix properly. And test coverage of the radio layer, which is zero by necessity.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": 'How is user data protected?', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'Mostly by not being there. Messages, tasks, crowd reports and alerts never leave the device. What is on the server sits behind deny-all row-level security, reachable only through narrow functions, with a tested restore for the backups.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": '125 tests — what’s your coverage percentage?', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'Do not invent one. “We haven’t measured line coverage. What I can tell you is exactly what the suite pins down and what it cannot reach” — then give the split.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Normal', "after": 1.0, "runs": [
        {"text": 'Is the password hashing strong enough?', "bold": True, "size": 10.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 5.0, "runs": [
        {"text": 'Each password gets its own random salt, which stops one cracked hash exposing every account sharing that password. A dedicated password-hashing function with a work factor would be stronger than a single SHA-256 pass — a fair criticism to accept rather than argue.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 1', "after": 6.0, "before": 12.0, "brk": True, "runs": [
        {"text": '4.  The question bank'},
    ]},
    {"t": "p", "style": 'Normal', "after": 8.0, "runs": [
        {"text": 'The first four are everybody’s — any of us can be asked them while another person is speaking. The rest are owned by the person named.', "italic": True, "size": 11.0, "color": '46555A'},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Everybody must be able to answer these'},
    ]},
    {"t": "p", "style": 'Normal', "after": 2.0, "runs": [
        {"text": 'So what is it?', "bold": True, "size": 11.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": 'Hops is a campus safety and social app that works with no internet, no mobile data and no signal. Phones talk straight to each other over Bluetooth, and messages hop device to device, so an emergency alert travels further than any one phone can reach. Seven of us should give roughly this same answer — learn it.', "size": 11.0},
    ]},
    {"t": "p", "style": 'Normal', "after": 2.0, "runs": [
        {"text": 'Why not just build a website or use WhatsApp?', "bold": True, "size": 11.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": 'Both need a working internet connection on the phone of the person in trouble. The scenario we built for is the one where that is missing. Hops needs two phones and nothing else.', "size": 11.0},
    ]},
    {"t": "p", "style": 'Normal', "after": 2.0, "runs": [
        {"text": 'How far does a message actually travel?', "bold": True, "size": 11.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": 'One hop is ordinary Bluetooth range — tens of metres, less through walls. The point is that it does not stop at one hop: every device that hears a flare rebroadcasts it, so the reach is set by how many phones are in the chain, not by any one radio. On a dense campus that is a long way; with two phones in a field it is two phones in a field. Do not quote a fixed number.', "size": 11.0},
    ]},
    {"t": "p", "style": 'Normal', "after": 2.0, "runs": [
        {"text": 'Can someone track me by listening to the broadcasts?', "bold": True, "size": 11.0, "color": '0F4761'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": 'Not from the presence beacon — it carries a token derived from a secret seed and a 15-minute window, and only someone you have exchanged seeds with can resolve it. The honest caveat: while a message is actually being broadcast, that coded string is visible as the phone’s Bluetooth name. Only a redesign removes that, and we know what it would take.', "size": 11.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Owned questions'},
    ]},
    {"t": "table", "widths": [4.5, 1.7], "rows": [
        ['Topic', 'Owner'],
        ['The problem, scope, schedule, team organisation', 'Victor'],
        ['Requirements, user testing, methodology', 'Hlonipha'],
        ['Interface decisions, features, visual design criticism', 'Sade'],
        ['Architecture, the three Bluetooth mechanisms, battery', 'Thrishen'],
        ['Wire protocol, byte budget, database, backups, server security', 'Elijah'],
        ['Emergency Flare, safety behaviour, concurrent alerts, abuse', 'Nabihah'],
        ['Cryptography, privacy, testing coverage, limitations, future work', 'Jocelyn'],
    ]},
    {"t": "p", "style": 'Normal', "after": 8.0, "runs": [
        {"text": 'Full answers are on each person’s page in section 3.', "italic": True, "size": 10.0, "color": '46555A'},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Questions we would rather be asked'},
    ]},
    {"t": "p", "style": 'Normal', "after": 8.0, "runs": [
        {"text": 'If the room goes quiet, offer one of these. It is better to steer than to stand there.', "size": 11.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": '“A question we get a lot is how far a message actually travels — Thrishen?”', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": '“People usually ask what stops someone faking an emergency — Nabihah can take that.”', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": '“If you’re interested in what the user testing threw up, Hlonipha has the data.”', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 1', "after": 6.0, "before": 12.0, "brk": True, "runs": [
        {"text": '5.  Pre-flight checklist'},
    ]},
    {"t": "p", "style": 'Normal', "after": 8.0, "runs": [
        {"text": 'Agree now who owns this list. It should be one person, and they should run it the morning of the presentation and again twenty minutes before.', "italic": True, "size": 11.0, "color": '46555A'},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Devices'},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Both demo phones charged above 60 per cent, and a charger in the room.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Bluetooth ON and location ON on both. Location is required for Bluetooth scanning on Android.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Device A: Hops uninstalled, so Victor’s first-run demo is genuinely a first run.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Device B: signed in, sitting on the radar, and in a teammate’s hand at the back of the room for the relay demos.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Confirm device A can actually advertise. Some handsets receive but cannot transmit — test with the ACTUAL phone, not a similar one.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Screen mirroring tested with the real room cable, not a different one that worked last week.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Notifications from other apps silenced on both phones. A WhatsApp banner mid-demo is avoidable.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Laptop'},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Deck open in Presenter View, with the speaker notes visible to you and not to the room.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Local PostgreSQL service running, and the local password known, for Elijah’s restore demo.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Dry-run the backup verification script end to end.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Backup screen recordings in one folder on the desktop, named by segment number.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Recordings to have ready (one tap away)'},
    ]},
    {"t": "table", "widths": [0.9, 3.9, 1.4], "rows": [
        ['Segment', 'Recording', 'Owner'],
        ['8', 'Full first-run: install, sign up, walkthrough, radar', 'Victor'],
        ['10', 'Vibe Check and Study Bunny across two devices', 'Sade'],
        ['11', 'Friend request, chat connecting, message delivered', 'Thrishen'],
        ['12', 'A successful backup verification run', 'Elijah'],
        ['13', 'Flare triggered on A, alarm on B, stand-down', 'Nabihah'],
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'The room'},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Arrive early enough to test the radio environment. A room full of laptops and phones is a crowded 2.4 GHz environment and it is the most likely cause of a failed demo.', "size": 10.0},
    ]},
    {"t": "p", "style": 'List Bullet', "after": 3.0, "runs": [
        {"text": 'Agree where each person stands and the order you rotate through. Practise the physical swap at least once.', "size": 10.0},
    ]},
    {"t": "p", "style": 'Heading 1', "after": 6.0, "before": 12.0, "brk": True, "runs": [
        {"text": '6.  When a demo fails'},
    ]},
    {"t": "p", "style": 'Normal', "after": 8.0, "runs": [
        {"text": 'Something probably will. How you handle it matters more than whether it happens — a group that recovers calmly reads as a group that has done this before.', "italic": True, "size": 11.0, "color": '46555A'},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'The rule'},
    ]},
    {"t": "p", "style": 'Normal', "after": 8.0, "runs": [
        {"text": 'Give it fifteen seconds. If it has not worked, stop, say what should have happened, say what you think went wrong, and go to the recording. Do not keep tapping in silence, and do not narrate your own panic.', "size": 11.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Wording that works'},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": '“That’s the one that’s least reliable across handsets — let me show you the recording and explain what you’d be seeing.”  ', "size": 11.0},
        {"text": 'Honest, unbothered, and it keeps the content coming.', "bold": True, "size": 11.0},
    ]},
    {"t": "p", "style": 'Normal', "indent": 0.25, "after": 8.0, "runs": [
        {"text": '“This room is a very crowded radio environment, which is exactly the condition that makes this hard. Here’s it working on a quieter network.”  ', "size": 11.0},
        {"text": 'True, and it turns the failure into a technical point.', "bold": True, "size": 11.0},
    ]},
    {"t": "p", "style": 'Heading 2', "after": 3.0, "before": 9.0, "runs": [
        {"text": 'Specific failures and what to say'},
    ]},
    {"t": "table", "widths": [1.8, 4.4], "rows": [
        ['What failed', 'What to say and do'],
        ['Sign-up will not complete', 'Identity is the one part that needs the network. Say so — it is consistent with what Thrishen said in segment 4 — and play the first-run recording.'],
        ['Chat will not connect (segment 11)', 'Most likely failure of the hour. Say that classic Bluetooth connection is the least reliable thing across handsets, then move to Community Alerts, which rides the broadcast channel and almost always works.'],
        ['A device does not appear on the radar', 'Check Bluetooth and location are both on. If still nothing, use the second phone pair, or show the recording. Do not restart the app on stage more than once.'],
        ['The flare will not send (segment 13)', 'If the app refuses it, that is correct behaviour on a handset without the transmit role — explain that, it is a good answer. Then play the recording.'],
        ['Backup script errors', 'Almost always the local PostgreSQL service not running. Do not debug on stage — show the previous run’s output and explain what it proves.'],
        ['Screen mirroring drops', 'Carry on talking to the slides while someone else fixes it. Never let the room watch seven people stare at a cable.'],
    ]},
    {"t": "p", "style": 'Heading 1', "after": 6.0, "before": 12.0, "brk": True, "runs": [
        {"text": '7.  Numbers everyone must get right'},
    ]},
    {"t": "p", "style": 'Normal', "after": 8.0, "runs": [
        {"text": 'If you are going to quote a figure, quote one of these. If you are not certain, describe it instead — one wrong number invites a judge to check all the others.', "italic": True, "size": 11.0, "color": '46555A'},
    ]},
    {"t": "table", "widths": [1.5, 1.3, 3.4], "rows": [
        ['Figure', 'Value', 'The caveat that goes with it'],
        ['Lines of Dart', '35,380', 'client/lib only — the app’s own Dart. Not the Kotlin, SQL, tests or website.'],
        ['Dart source files', '100', 'Same scope as above.'],
        ['Automated tests', '125', 'All passing. Not a coverage figure — nothing radio-related is covered.'],
        ['Tests on the wire format', '57', 'The single highest-value test file in the project.'],
        ['Bluetooth mechanisms', '3', 'BLE broadcast, classic RFCOMM, Nearby Connections.'],
        ['Advertisement budget', '24 bytes', 'Out of a 31-byte packet. 26 would fit; 24 leaves margin.'],
        ['Text per chunk', '11 bytes', '13 bytes of the 24 are overhead.'],
        ['Max message length', '88 bytes', '8 chunks maximum, 11 bytes each.'],
        ['Flare duration', '60 seconds', 'Raised from 30. An admin official alert keeps its own 30.'],
        ['Identity rotation', '15 minutes', 'Same order as the Apple/Google exposure-notification scheme.'],
        ['Signature', 'RSA-2048', 'About 256 bytes, split across 18-byte chunks.'],
        ['Optional features', '8', 'Plus the always-on ones, which are not in the catalogue.'],
        ['Backend tables', '8', 'Row-level security on all, zero policies — deny-all by design.'],
        ['Secured functions', '65', 'With 74 revocations and 61 explicit grants.'],
        ['Database migrations', '19', 'Numbered 0001 upward.'],
        ['Last verified restore', '8/8 tables, 67/67 rows', 'Into a local scratch database, offline.'],
        ['User-testing sample', '13 students', '54 rated items each. August 2026, on an earlier build.'],
    ]},
    {"t": "p", "style": 'Normal', "after": 8.0, "runs": [
        {"text": 'One last thing.  ', "bold": True, "size": 11.0, "color": 'B23A1E'},
        {"text": 'The two figures most likely to trip someone up are the line count and the test count. Neither is a claim about the whole repository, and neither is a coverage percentage. If a judge pushes on either, the correct move is to narrow the claim immediately rather than defend a bigger one.', "size": 11.0},
    ]},
]

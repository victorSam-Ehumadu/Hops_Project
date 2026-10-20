# Slide content for the Group 18 presentation deck.
#
# Data only — build_deck.py owns the layout. Extracted from the
# committed .pptx so the generator reproduces it exactly.
#
# Each entry is one slide, in order. "kind" selects the builder.

SLIDES = [
    {
        "kind": 'title', "n": 1,
        "notes": """Hold here while everyone settles. One person opens — do not all stand at the front.

Victor: 'Good morning. We're Group 18, and this is Hops — a campus safety network that keeps working when the internet doesn't.'

Then straight into the running order slide. Do not read the team names aloud; they are on the slide.""",
    },
    {
        "kind": 'running_order', "n": 2,
        "notes": """Victor delivers this in under 40 seconds. The point of the slide is to buy the audience's patience for round one by promising live software in round two, and to signal that we want questions.

Say the last line out loud — it is the thesis of the whole project.""",
    },
    {
        "kind": 'divider', "n": 3,
        "num": 'ROUND ONE  ·  SEGMENTS 1 TO 7',
        "label": 'Why, and how',
        "blurb": 'The problem we chose, the architecture it forced on us, and the three things we had to get right.',
        "notes": "Transition slide. Whoever is finishing clicks to it and names who is next: '<name> will take you through <topic>.' Then physically swap position. Do not narrate this slide.",
    },
    {
        "kind": 'content', "n": 4,
        "seg": 1,
        "member": 'Victor',
        "dur": '2 min',
        "title": 'Every campus safety app assumes the internet works',
        "bullets": [
            ('The phone is dead weight when it matters.', 'Out of data, no signal in a stairwell or basement corridor, or the network itself down during the incident that caused it.'),
            ('Students already have the hardware.', 'Every phone in the room has a Bluetooth radio that works at zero cost, with no contract and no coverage map.'),
            ('Nobody is using it.', 'Bluetooth on campus is used to pair headphones. It is a second network, sitting idle, that does not care whether the internet is up.'),
        ],
        "notes": """Victor opens. 2.5 minutes for segments 1 and its second slide combined — do not overrun, the live demo in round two is what wins marks and it is at the back.

Script: 'Every campus safety app we looked at has the same assumption buried in it — that the phone has a working internet connection. That assumption fails exactly when you need it most.'

Give ONE concrete scenario, not three. The basement corridor is the best one: everyone has been somewhere on campus with no signal.

Do NOT claim campus crime statistics we cannot cite. Stick to the technical gap.""",
    },
    {
        "kind": 'quote', "n": 5,
        "seg": 1,
        "member": 'Victor',
        "dur": '30 sec',
        "big": 'Hops is a campus safety network that works with no internet, no mobile data and no signal.',
        "sub": 'Phones talk straight to each other over Bluetooth, and messages hop device to device — so an alert travels further than any one phone can reach.',
        "notes": """This is THE slide. Everyone on the team must be able to say this sentence from memory, because a judge may ask any of us 'so what is it?' and seven different answers is the worst outcome of the hour.

Victor says it once, slowly, then stops. Let it sit for a beat before clicking on.

Then the second half: 'Around that safety core we built the everyday reasons to keep it installed — because an app nobody opens is not running on the day it matters.' That sentence pre-empts the 'why would students install this?' question.""",
    },
    {
        "kind": 'content', "n": 6,
        "seg": 2,
        "member": 'Hlonipha',
        "dur": '2 min',
        "title": 'What it had to do, and how we found out',
        "bullets": [
            ('Observation and participation.', 'We are the users. Seven students on this campus, mapping where signal actually drops and what people already do instead.'),
            ('A structured study of thirteen students.', 'First to third year, across BSc IT, Diploma and Higher Certificate. Fifty-four rated items covering every screen, plus free-text answers.'),
            ('Five of us ran it in person.', 'Face to face, on a device, watching where people hesitated — which is how we caught problems a questionnaire alone would have missed.'),
        ],
        "notes": """Hlonipha. This segment exists to prove the requirements were not invented at a table.

The strongest thing you have is that you watched people use it rather than only asking them. Say the word 'hesitated' — it signals real usability work.

Do not go through findings here. That is your round-two segment (09) and repeating it wastes both slots. Here you only establish the method.

If a judge interrupts to ask the sample size: 'thirteen, which is small — we treated it as qualitative and we are running a second round.' Own it, do not defend it.""",
    },
    {
        "kind": 'content', "n": 7,
        "seg": 2,
        "member": 'Hlonipha',
        "dur": '90 sec',
        "title": 'The requirements that actually shaped the build',
        "bullets": [
            ('It must work with no connection at all.', 'Not degrade gracefully — work. This single requirement is what ruled out every conventional architecture.'),
            ("An alert must outrun one phone's range.", 'Which means other devices have to pass it on, not just receive it.'),
            ('It must not become a tracking device.', 'A safety app that broadcasts constantly is a surveillance tool unless identity is handled deliberately.'),
            ("A stranger's alert must be verifiable offline.", 'If anyone can forge an emergency, the alarm becomes noise and people turn it off.'),
        ],
        "notes": """These four are the functional spine, and each one maps to a later segment: Thrishen (04) answers the first two, Jocelyn (07) answers the last two.

Say that mapping out loud — 'you'll see how we met each of these' — it makes the whole presentation feel designed rather than assembled.

The third requirement is the one judges respect most, because most student projects do not think about it at all.""",
    },
    {
        "kind": 'content', "n": 8,
        "seg": 3,
        "member": 'Sade',
        "dur": '2 min',
        "title": 'The app a student actually opens',
        "bullets": [
            ('Five tabs, and the first one is a radar.', "Nearby devices as anonymous dots. It is the home screen because 'who is around me' is the question the whole app answers."),
            ('Features are opt-in.', 'Eight optional mini-apps in a catalogue. A user adds what they want; the rest stay out of their way instead of crowding the interface.'),
            ('The safety feature has no button.', 'Emergency Flare is deliberately not on any screen — Nabihah explains why in segment 6.'),
        ],
        "notes": """Sade. You own the interface, so this is your territory — speak with authority about the decisions, not just the layout.

The opt-in catalogue is a genuinely good design answer to feature bloat. Lead with it.

The 'no button' line is a deliberate hook — it makes the audience curious and hands Nabihah a warm room three segments later. Do not explain it yourself.

Resist walking through all eight features. You demo them in segment 10.""",
    },
    {
        "kind": 'stat', "n": 9,
        "seg": 3,
        "member": 'Sade',
        "dur": '30 sec',
        "title": 'Built, not mocked up',
        "stats": [
            ('100', 'DART SOURCE FILES'),
            ('35,380', 'LINES OF DART IN THE APP'),
            ('8', 'OPTIONAL FEATURES'),
            ('2', 'APPS FROM ONE CODEBASE'),
            ('5', 'TABS IN THE STUDENT APP'),
            ('125', 'AUTOMATED TESTS PASSING'),
        ],
        "notes": """Sade. Thirty seconds on this slide, no more. Its only job is to establish that this is a real build before the technical segments start.

Point at '2 apps from one codebase' and explain it in one line: 'the student app and the admin app are two entry points into the same package — same APK, different front door.' That is an architecture decision judges notice.

IMPORTANT: 35,380 lines is client/lib only — the Flutter app's own Dart. If asked, say that plainly. Do not let it sound like the whole repository.""",
    },
    {
        "kind": 'quote', "n": 10,
        "seg": 4,
        "member": 'Thrishen',
        "dur": '45 sec',
        "big": 'There is no server in the middle.',
        "sub": 'Your messages, tasks, crowd reports and alerts never reach one. They exist only on the devices that heard them.',
        "notes": """Thrishen. This is the claim judges most often assume is untrue, so state it flatly and then immediately concede the one exception before anyone can catch you on it:

'We do have a backend — but it only holds who you are and the moderation records. No message ever passes through it.'

Conceding the exception yourself is what makes the claim credible. If a judge extracts it from you instead, it sounds like you were overselling.""",
    },
    {
        "kind": 'visual', "n": 11,
        "seg": 4,
        "member": 'Thrishen',
        "dur": '45 sec',
        "title": 'Why not just use one?',
        "image": 'd_noserver.png',
        "width": 10.4,
        "caption": 'Connecting to each phone in turn takes seconds per device. An emergency does not have them.',
        "notes": """Thrishen. Let the picture do the work: left is what they are expecting, right is what we built. Point at the right-hand side and say 'no server on the path at all', then immediately concede the exception yourself — the backend holds identity and moderation.

Conceding it before a judge extracts it is what makes the claim credible.""",
    },
    {
        "kind": 'content', "n": 12,
        "seg": 4,
        "member": 'Thrishen',
        "dur": '2 min',
        "title": 'Three radios, three different jobs',
        "mono_tail": 'ble_peripheral + flutter_blue_plus   ·   Kotlin RFCOMM sockets   ·   nearby_connections',
        "bullets": [
            ('BLE advertisement broadcast.', 'Presence, alerts, flares, requests, crowd reports. One device reaches everyone in range at once without connecting to anyone. This is the mesh.'),
            ('Classic Bluetooth RFCOMM.', 'Real 1:1 chat. A conversation needs a reliable two-way stream, which a broadcast cannot give you.'),
            ('Google Nearby Connections.', 'File transfer only. Needs throughput and resumable progress, so it negotiates the fastest transport available.'),
        ],
        "notes": """Thrishen. 'It uses Bluetooth' is not good enough — being able to say which mechanism does what is the clearest proof on stage that we understand our own system.

Expect: 'why not just use one?' Answer: 'the three jobs have incompatible shapes — broadcast-to-everyone, reliable-stream-to-one, and bulk-file-to-one. Forcing them down one mechanism means either a chat that cannot hold a sentence, or an alert that has to connect to each phone in turn — and connecting takes seconds per device, which an emergency does not have.'

Have that answer ready verbatim. It is the single best question you can be asked.""",
    },
    {
        "kind": 'visual', "n": 13,
        "seg": 4,
        "member": 'Thrishen',
        "dur": '60 sec',
        "title": 'Three jobs, three mechanisms',
        "image": 'd_radios.png',
        "width": 10.6,
        "caption": "Forcing all three down one path means a chat that can't hold a sentence, or an alert that connects to phones one at a time.",
        "notes": """Thrishen. This is the slide to linger on if a judge looks technical — being able to say which mechanism does what is the clearest proof we understand our own system.

The megaphone/phone call/courier framing is there so a non-technical judge follows it too. Use the plain words first; use BLE, RFCOMM and Nearby Connections only if they do.""",
    },
    {
        "kind": 'content', "n": 14,
        "seg": 5,
        "member": 'Elijah',
        "dur": '2 min',
        "title": 'The whole protocol fits in 24 bytes',
        "bullets": [
            ('A Bluetooth advertisement packet is capped at 31 bytes.', "Headers and our service identifier eat most of it. After the name's own header and a transmit-power field Android adds whether we ask or not, 26 remain."),
            ('We budget 24, not 26.', 'Two bytes of margin, because an over-long name does not truncate — the entire advertisement is rejected and the message silently never leaves the phone.'),
            ('So each device renames itself.', 'The advertisement name IS the message. A prefix says which kind of event it is, and every other device reads those names as they sweep past.'),
        ],
        "notes": """Elijah. This is the most distinctive engineering in the project — give it room.

The hook is the absurdity of the number: 'the entire protocol for this app fits in twenty-four bytes. That is shorter than this sentence.'

The rejection behaviour is the detail that shows real hardware experience — a packet one byte over does not get cut short, it never transmits at all. We found that the hard way.

Next slide has the byte layout. Walk it left to right.""",
    },
    {
        "kind": 'visual', "n": 15,
        "seg": 5,
        "member": 'Elijah',
        "dur": '90 sec',
        "title": 'Every character accounted for',
        "image": 'd_packet.png',
        "width": 11.2,
        "caption": 'Go one character over and the whole broadcast is rejected — it does not get shortened.',
        "notes": """Elijah. Walk it left to right, naming each block. Then land the consequence: eleven characters left, so a longer message is chopped into up to eight of these and put back together on the other side — 88 characters in total.

Then the detail that shows real hardware work: a split must never land in the middle of a multi-byte character, or the message arrives as nonsense. There is a test for exactly that.

If asked where the signature goes: it does not fit, so it rides a second small slot on the same broadcast, 18 bytes at a time. Hand that to Nabihah.""",
    },
    {
        "kind": 'content', "n": 16,
        "seg": 5,
        "member": 'Elijah',
        "dur": '45 sec',
        "title": 'Where the data actually lives',
        "bullets": [
            ('On the phone.', 'Four local database tables — chat log, crowd reports, tasks, contact profiles. Schema version 10, SQLite.'),
            ('Small state in preferences.', 'Session token, enabled features, theme, balance, streaks.'),
            ('Secrets in the platform secure store.', 'The private key and the identity seed. Neither is ever transmitted after it is generated.'),
            ('On the server: identity and moderation only.', 'Account, password hash, public key, role, reports, admin log. Nothing else.'),
        ],
        "notes": """Elijah. You are the database developer, so this is yours. Thirty to forty seconds.

The line that matters: 'the strongest privacy guarantee we have is that most of this data is not on a server to leak.'

That hands straight to Nabihah on safety and Jocelyn on security. Say 'Nabihah' as you click.""",
    },
    {
        "kind": 'content', "n": 17,
        "seg": 6,
        "member": 'Nabihah',
        "dur": '2 min',
        "title": 'Emergency Flare',
        "kicker": 'The feature the whole architecture exists for.',
        "bullets": [
            ('One press, with confirmation.', 'A flare broadcasts who you are and a short reason, and stays live for sixty seconds.'),
            ('Every phone that hears it passes it on.', 'Which is how the alert reaches past the range of the phone that sent it. That relay is the mesh doing its job.'),
            ('Every phone that hears it sounds an alarm.', 'A looping siren and a notification, on devices whose owners you have never met.'),
            ('It is signed.', 'So a receiver can prove it came from a real account — with no internet, which Jocelyn explains next.'),
        ],
        "notes": """Nabihah. Slow down here. This is the emotional centre of the presentation and rushing it undercuts everything.

Sixty seconds, not thirty — and the reason is good: 'we raised it from thirty because thirty closed the window while someone was still working out where the sound was coming from.' That is evidence of testing with real people.

Do NOT trigger a flare during this segment. It is demonstrated properly in segment 13 with two devices and a warning to the room first.""",
    },
    {
        "kind": 'visual', "n": 18,
        "seg": 6,
        "member": 'Nabihah',
        "dur": '60 sec',
        "title": 'How an alert outruns one phone',
        "image": 'd_mesh.png',
        "width": 10.8,
        "caption": 'Nobody in this chain needs to know each other, or to have met before.',
        "notes": """Nabihah. This is the picture that explains the whole architecture in one go.

Trace it with your hand, left to right. 'I set one off. Her phone hears it and repeats it. His phone hears hers and repeats it. None of those people know me.'

Then pre-empt the range question: how far it goes depends on how many Hops phones are in the chain, not on any one radio. Do NOT quote a distance in metres.""",
    },
    {
        "kind": 'content', "n": 19,
        "seg": 6,
        "member": 'Nabihah',
        "dur": '90 sec',
        "title": 'Why there is no button for it',
        "bullets": [
            ('It is not on any screen.', 'The only ways in are the Android Quick Settings tile and a long-press on the app icon. Both open the same confirm-then-reason dialog.'),
            ('We built a volume-button gesture and removed it.', 'It worked on some handsets and silently did nothing on others, because manufacturer skins intercept volume keys before the app ever sees them.'),
            ("A safety feature that works 'sometimes' is worse than none.", 'It teaches a gesture the user then trusts. We would rather ship fewer ways in than one that quietly fails.'),
        ],
        "notes": """Nabihah. This is the best judgement story we have — a deliberate removal, for a reason we can articulate. Judges reward that far more than another feature.

Land the last line as a principle: 'a safety feature that works sometimes is worse than not having it, because it teaches a gesture the user then trusts.'

If asked why no in-app button at all: a screen you have to unlock, open and navigate is not reachable in the situation this exists for. The Quick Settings tile works from the lock screen.""",
    },
    {
        "kind": 'content', "n": 20,
        "seg": 6,
        "member": 'Nabihah',
        "dur": '45 sec',
        "title": 'Two people in trouble at once',
        "kicker": 'Treated as a normal case, not an edge case.',
        "bullets": [
            ('Relays are queued, never overlapped.', 'There is one broadcast slot. Two relays at once cut each other short — so each gets its own window in turn.'),
            ("Our own flare outranks relaying anyone else's.", 'Nobody else can send ours. Theirs is already being relayed by every other device that heard it.'),
            ('Alarms stack; stand-downs are scoped.', "One siren covers any number of alerts, and cancelling one person's alarm never silences another's."),
            ('Every alert expires on its own.', 'A stand-down is a broadcast like any other and can simply never arrive. Without expiry, an orphaned alarm would ring forever.'),
        ],
        "notes": """Nabihah. Every one of these four cost us a real bug, and saying so is a strength: 'we learned each of these by getting it wrong first.'

The self-expiry one is the most sophisticated point in the segment — a stand-down message can simply never arrive, so the alert has to be able to end itself. That is distributed-systems thinking and a technical judge will notice it.

Keep this to 45 seconds. Four short claims, then hand to Jocelyn.""",
    },
    {
        "kind": 'content', "n": 21,
        "seg": 7,
        "member": 'Jocelyn',
        "dur": '2 min',
        "title": 'Proving who sent an alert, with no internet',
        "bullets": [
            ('A keypair is generated on your phone at sign-up.', 'The public half goes to our backend. The private half goes into the platform secure store and is never transmitted again.'),
            ('That key signs flares and official alerts.', 'The two messages where a forgery would actually be dangerous.'),
            ('Public keys are cached on every device.', "So once a phone has synced even once, it can verify a stranger's alert with no network at all. An unverified flare is shown as unverified."),
            ('An RSA signature is 256 bytes.', 'Far too big for a 24-byte packet, so it is split across 18-byte chunks riding the same broadcasts.'),
        ],
        "notes": """Jocelyn. The offline-verification point is genuinely the cleverest thing in the project. Make sure it lands:

'The phone receiving the alert does not need the internet to check it. It already has the public keys cached — so it can verify an alert from someone it has never met, in a building with no signal.'

BE PRECISE, and volunteer the limit: only flares and official alerts are signed. The rest of the mesh is not, because signatures do not fit in 24 bytes and we spent them where forgery causes harm. Say that before a judge finds it — it reads as scoping, not a gap.""",
    },
    {
        "kind": 'content', "n": 22,
        "seg": 7,
        "member": 'Jocelyn',
        "dur": '90 sec',
        "title": 'An app that broadcasts constantly could track you',
        "bullets": [
            ('So the presence beacon carries no name.', 'It carries a token derived from a secret seed and the current fifteen-minute window, so it changes on its own with no coordination between devices.'),
            ('The seed is never transmitted.', 'Only someone you have already exchanged seeds with — once, over an encrypted chat session — can recompute the token and recognise you.'),
            ('Everyone else sees an opaque string.', 'A generic Bluetooth scanner in a corridor cannot log who walked past, because what it records stops being valid every quarter of an hour.'),
            ('This is the exposure-notification approach.', 'The same rolling-identifier scheme, and the same order of rotation interval, that Apple and Google used for contact tracing.'),
        ],
        "notes": """Jocelyn. Set up the threat concretely first: 'anyone with a free Bluetooth scanner app could sit in a corridor, log what it hears, and reconstruct who walked past and when. A fixed username in that beacon would make Hops a campus-wide tracking device.'

Naming the Apple/Google precedent is worth saying — it shows we did not invent a scheme where a known-good one exists.

The honest caveat is on the next slide. Do not skip it.""",
    },
    {
        "kind": 'visual', "n": 23,
        "seg": 7,
        "member": 'Jocelyn',
        "dur": '60 sec',
        "title": 'Changing disguise four times an hour',
        "image": 'd_rotate.png',
        "width": 10.6,
        "caption": 'Same phone, four different codes. The secret behind them never leaves the device.',
        "notes": """Jocelyn. Set the threat up BEFORE you show this: anyone with a free scanner app could sit in a corridor, log what it hears, and work out who walked past and when. A fixed username in that broadcast would make Hops a tracking device.

Then the picture answers it. Four codes, same phone, fifteen minutes apart.

Worth naming the precedent: this is the same scheme, and roughly the same interval, that Apple and Google used for contact tracing. It shows we did not invent our own crypto where a known-good approach already existed.""",
    },
    {
        "kind": 'content', "n": 24,
        "seg": 7,
        "member": 'Jocelyn',
        "dur": '60 sec',
        "title": 'What we have not solved',
        "bullets": [
            ("On Android, the broadcast name is the phone's Bluetooth name.", 'The platform gives us no separate field. So while a message is actually on the air, that coded string is what nearby devices show in their Bluetooth list.'),
            ('We built a guard, and it is not a complete fix.', "It saves the real name, restores it afterwards and on shutdown, and refuses to mistake a protocol string for the user's real name. What it cannot remove is the window while the broadcast is live."),
            ('Fixing it properly means a redesign.', 'Moving payloads off the advertisement name entirely. That is honest work we have not done, not a bug we missed.'),
        ],
        "notes": """Jocelyn. Volunteering this is a deliberate strategy. A judge who finds a weakness you hid stops trusting everything else you said; a judge you hand it to reads it as engineering maturity.

Delivery matters — state it as a known, bounded limitation with a known fix, not as an apology. 'This is the thing we would fix first, and we know exactly what it would take.'

Then hand to the break between rounds: 'that's the design. Victor is going to show you it running.'""",
    },
    {
        "kind": 'divider', "n": 25,
        "num": 'ROUND TWO  ·  SEGMENTS 8 TO 14',
        "label": 'Running on real devices',
        "blurb": 'Each of us now shows the part we just explained. Everything from here is live.',
        "notes": "Transition slide. Whoever is finishing clicks to it and names who is next: '<name> will take you through <topic>.' Then physically swap position. Do not narrate this slide.",
    },
    {
        "kind": 'demo', "n": 26,
        "seg": 8,
        "member": 'Victor',
        "dur": '3 min',
        "live": True,
        "title": 'First run, and the radar',
        "fallback": 'Screen-record the whole first-run flow in advance and keep it one tap away. If sign-up needs the network and the venue wifi is down, play the recording and say so plainly.',
        "steps": [
            'Install is a single APK — no store, no account provisioning, no server to point it at.',
            'Sign up on device A. Watch the key generation step: that is the keypair being created on the phone.',
            'Accept terms, then the walkthrough — this is what the thirteen testers saw.',
            'Land on the radar. Device B is already running, so it appears as a dot within a few seconds.',
            "Show that the dot has no name on it. That is Jocelyn's rotating token doing its job.",
        ],
        "notes": """Victor. This is the first live moment, so it sets expectations for the whole of round two. Rehearse it until it is boring.

PRE-FLIGHT, before the session starts: both phones charged above 60%, Bluetooth on, location on, Hops uninstalled from device A so first-run is genuinely first-run, device B signed in and sitting on the radar, screen mirroring tested with the actual room cable.

Narrate what you are tapping — the audience is watching a mirrored phone screen and will lose you otherwise.

The unnamed dot is the moment to point at: 'that device is my teammate's phone, and it does not say so. That is deliberate.'""",
    },
    {
        "kind": 'visual', "n": 27,
        "seg": 9,
        "member": 'Hlonipha',
        "dur": '75 sec',
        "title": 'What thirteen students told us',
        "image": 'd_survey.png',
        "width": 10.8,
        "caption": 'Mean 4.57 out of 5 across 54 items. Twelve of the thirteen would use it regularly.',
        "notes": """Hlonipha. Lead with the honest good news — 4.57 overall, 12 of 13 would use it regularly — then spend most of your time at the BOTTOM of this chart. That ordering is what makes the praise believable.

Say '12 of 13', never '100%'. One answered 'maybe', and a judge who checks will find it.

The bar that matters is Emergency Flare at 4.38, third from bottom. That is the feature the whole app exists for, and the weakest question inside it was whether people understood that a flare alerts the people around them. Point at it deliberately — the next slide is what that means.""",
    },
    {
        "kind": 'content', "n": 28,
        "seg": 9,
        "member": 'Hlonipha',
        "dur": '2 min',
        "title": 'Three things we got wrong',
        "bullets": [
            ('The Bluetooth density indicator did not explain itself.', 'Our lowest-scoring item on the whole study. People could see it and could not tell what it was for.'),
            ('Nobody could find Received Files.', 'A feature that works perfectly and is unreachable is a feature that does not work.'),
            ('Emergency Flare scored third-lowest of fourteen areas.', 'The weakest item in it was whether people understood that a flare alerts the people around them — 4.15. That is the feature the whole app exists for, so that is the one we would fix first.'),
            ('What they asked for, they got.', 'The most common request was a proper dark mode and more colour choice. There is now a theme catalogue, and that is a direct result of this study.'),
        ],
        "notes": """Hlonipha. Quoting 'it's ugly' out loud is a deliberate choice — it is real data, it gets a laugh, and it buys enormous credibility for everything else we claim. Say it with a straight face.

The arc of this segment is: we tested, we found real failures, we fixed what we could, and the two discoverability problems are on the list and not yet done.

Do NOT claim the discoverability issues are fixed. They are in Jocelyn's future-scope segment.""",
    },
    {
        "kind": 'demo', "n": 29,
        "seg": 10,
        "member": 'Sade',
        "dur": '3 min',
        "live": True,
        "title": 'The everyday features',
        "fallback": 'Airplane mode is the fallback that always works — if a peer-to-peer feature will not connect, switch to Task Tracker in airplane mode and make the offline point instead.',
        "steps": [
            'Features tab: add Vibe Check from the catalogue — show that the catalogue is opt-in.',
            "Tag the room's crowd level on device A. It appears on device B with no account link between them.",
            'Study Bunny Finder: broadcast a module code on A, find it on B. Anonymous, five-minute life.',
            'Lost & Found: post an item. This one relays hop-to-hop like a flare, so it travels past direct range.',
            'Task Tracker, offline: put both phones in airplane mode first, then add a task with a deadline.',
        ],
        "notes": """Sade. Five features in three minutes is tight. Pick the three that work most reliably on the day and cut the rest — a clean three beats a rushed five.

The airplane-mode moment is the most persuasive thing in the entire presentation. Turn it on in front of the room, hold the phone up so the icon is visible, and then use the app. Do not rush past it.

Vibe Check and Study Bunny carry no sender identity at all — say so, it reinforces Jocelyn's privacy segment.

If the room is empty of other Hops devices, Lost & Found relay will look like nothing happens. Have device B in a colleague's hand at the back of the room.""",
    },
    {
        "kind": 'demo', "n": 30,
        "seg": 11,
        "member": 'Thrishen',
        "dur": '3 min',
        "live": True,
        "title": 'Chat, and the second radio',
        "fallback": "RFCOMM connection can hang on some Bluetooth stacks. If chat will not connect within about fifteen seconds, stop, say 'this is the one that is least reliable across handsets', and move to Community Alerts instead.",
        "steps": [
            'Contacts on device A: send a friend request to B. That request is a BLE broadcast, not a server call.',
            "Accept on B. Both devices now hold each other's identity seed.",
            'Open a chat and send a message. This is the RFCOMM socket — a real connection, not a broadcast.',
            'Show the avatar and bio appearing on the other side: that is the profile exchange over the same socket.',
            'Community Alerts: send a long message and point out it is being split into chunks and reassembled.',
        ],
        "notes": """Thrishen. You explained the three radios in segment 4 — this is where two of them become real, so refer back explicitly: 'the friend request was mechanism one, this chat is mechanism two.'

KNOWN RISK: this is the least reliable demo we have. Classic Bluetooth connection can hang indefinitely on some stacks — we added a timeout that closes the socket, but it can still fail in a crowded radio environment, which a presentation room absolutely is.

Have it already connected before you start if you can. Reconnecting live is the risky part, not sending the message.

The chunking in Community Alerts is Elijah's 24-byte budget made visible. Call that back too.""",
    },
    {
        "kind": 'content', "n": 31,
        "seg": 12,
        "member": 'Elijah',
        "dur": '90 sec',
        "title": 'The backend trusts nothing the client says',
        "bullets": [
            ('Eight tables, row-level security on all of them, zero policies.', 'Zero is not an oversight. It is deny-all: no client can read or write any table directly, ever.'),
            ('Everything goes through 65 narrow functions.', 'Each validates its own inputs and runs with its own authority. 74 permission revocations and 61 explicit grants define exactly what a client may call.'),
            ('Moderation has an audit trail.', 'Students report content, admins act on it, the reporter is notified — and every admin action is written to an append-only log.'),
        ],
        "notes": """Elijah. 'Zero policies' sounds like a mistake until you explain it, so explain it in the same breath: 'row-level security with no policies means deny-all. Nothing gets read or written directly. Every single operation goes through a function we wrote and locked down.'

That is a genuinely strong security posture and most student projects do not have it. Claim it.

Then move to the backup demo — that is the part people remember.""",
    },
    {
        "kind": 'demo', "n": 32,
        "seg": 12,
        "member": 'Elijah',
        "dur": '90 sec',
        "live": True,
        "title": 'Restoring the database, live and offline',
        "fallback": "The script is offline by design, so the only real risk is the local PostgreSQL service not running. Check it before the session. If it fails, show the previous run's output.",
        "steps": [
            'Run the verification script from the repository root. It needs no network at all.',
            'It restores the most recent dump into a scratch database on this laptop.',
            'It then counts what came back and reports it: tables restored, rows restored.',
            'Last verified run returned 8 of 8 tables and 67 of 67 rows.',
        ],
        "notes": """Elijah. This is a quietly spectacular demo because almost nobody does it. Have the line ready:

'An untested backup isn't a backup. So ours has a script that proves it restores — and it never touches the cloud, which is why I can run it in this room with the wifi off.'

PRE-FLIGHT: confirm the local PostgreSQL service is running and that you know the local password. Do a full dry run the morning of. The script reads its connection string from a prompt, never an argument, so nothing sensitive ends up in shell history — worth mentioning if a judge asks about credential handling.

There is a runbook for doing this as a demonstration: docs/backup-demo-runbook.md.""",
    },
    {
        "kind": 'demo', "n": 33,
        "seg": 13,
        "member": 'Nabihah',
        "dur": '3 min',
        "live": True,
        "title": 'Emergency Flare, on two devices',
        "fallback": 'If device A cannot advertise, the app refuses the flare and says so — that is correct behaviour, not a crash. Explain it, then play the recorded version.',
        "steps": [
            'Warn the room first: there is going to be a siren, and it is loud.',
            'Both phones in airplane mode, Bluetooth on. There is now no internet involved at all.',
            'Trigger from the Quick Settings tile on device A — not from inside the app, because there is no button.',
            'Confirm, pick a reason. Device B alarms within seconds, showing the sender and the reason.',
            'Point out the verified marker on B: that signature was checked with no network.',
            "Stand down from A. Show that B's alarm stops, and that it would have expired on its own anyway.",
        ],
        "notes": """Nabihah. The most important ninety seconds of the hour. Rehearse it until it is muscle memory.

WARN THE ROOM. An unannounced emergency siren in a presentation is genuinely unpleasant and it will cost you goodwill. 'There's going to be an alarm in about twenty seconds, and it's designed to be impossible to ignore.'

Airplane mode on BOTH phones, visibly, before you trigger. That is what makes this undeniable.

The verified marker is the payoff of Jocelyn's segment 7 — point at it and say so.

PRE-FLIGHT: confirm device A supports Bluetooth advertising at all. Some handsets can receive and not transmit, and the app will correctly refuse. Test with the ACTUAL phone you will use, and have a screen recording as backup.""",
    },
    {
        "kind": 'demo', "n": 34,
        "seg": 13,
        "member": 'Nabihah',
        "dur": '60 sec',
        "live": True,
        "title": 'An official alert from the admin app',
        "fallback": 'If the admin app will not sign in (it needs the network for that one step), show a recording and explain that sending the alert itself does not need a connection.',
        "steps": [
            'Same APK, second entry point — show it launching as the admin app.',
            'Sign in with an admin account. Note it cannot create one; admin accounts are provisioned out of band.',
            'Compose a campus-wide alert and send it.',
            "Both student devices receive it, styled as official and marked verified against the admin's key.",
        ],
        "notes": """Nabihah. Keep this to 60 seconds — the student flare was the main event.

The point worth making: 'this is the same APK. One package, two entry points, and the admin app is deliberately thinner — no local database, no games, no onboarding.'

Admin sign-in DOES need the network. Be upfront about that: identity is the one thing that is online, which is exactly what Thrishen said in segment 4.

An official alert keeps its own 30-second window, separate from the student flare's 60.""",
    },
    {
        "kind": 'content', "n": 35,
        "seg": 14,
        "member": 'Jocelyn',
        "dur": '90 sec',
        "title": 'How we know it works',
        "bullets": [
            ('125 automated tests, all passing.', '57 of them pin the wire format alone — budget arithmetic, chunk round trips, rotating tokens, signature reassembly.'),
            ('The password rules are tested hard.', "Including that the weak-password blocklist is checked before the character rules, because underneath them it would be unreachable — and that it catches 'P@ssw0rd1', not just 'password'."),
            ('One test reads the source rather than running it.', 'A revert path that takes our own emergency off the air can only be caught on two phones — so a test now fails the build if anyone writes one by hand. We found that bug and closed it this way.'),
            ('Nothing about the radios is automated, and nothing can be.', 'BLE, RFCOMM and Nearby need two physical devices in a room. Everything you watched in round two was verified by hand, repeatedly, on real phones.'),
        ],
        "notes": """Jocelyn. Precision here is worth more than a bigger number. A technical judge will respect '125 tests and here is exactly what they do not cover' far more than a vague claim of good coverage.

Volunteer the gap before you are asked: the local database layer is untested because it needs channel mocking and a native SQLite binary, and it is the obvious next target.

If asked how peer-to-peer features are verified: 'by hand, on two devices, every time. There is no way around that and we are not going to pretend there is.'""",
    },
    {
        "kind": 'visual', "n": 36,
        "seg": 14,
        "member": 'Jocelyn',
        "dur": '60 sec',
        "title": 'The shape of our testing',
        "image": 'd_pyramid.png',
        "width": 10.6,
        "caption": '125 automated tests sit under a layer that cannot be automated at all.',
        "notes": """Jocelyn. The shape of this picture IS the argument. A normal testing pyramid has manual work as a thin tip on top. Ours has a whole band that can never be automated, because BLE, RFCOMM and Nearby Connections need two real phones in a room.

Say it plainly rather than hiding it. 'Everything you watched in round two was verified by hand, repeatedly, on real devices' is a stronger answer than a coverage percentage you would then have to defend.

Volunteer the gap too: the on-phone database is untested, and it is the obvious next target.""",
    },
    {
        "kind": 'content', "n": 37,
        "seg": 14,
        "member": 'Jocelyn',
        "dur": '60 sec',
        "title": 'What we would do next',
        "bullets": [
            ('Move the protocol off the advertisement name.', 'The one unsolved privacy limitation, and the first thing we would fix.'),
            ('Get the local database under test.', 'The only untested component that does not need two phones in a room.'),
            ('Fix the two discoverability failures the study found.', 'The density indicator and the route to received files. Both work; neither explains itself.'),
            ('A second round of user testing.', 'Thirteen people on an August build is a start, not an evaluation.'),
        ],
        "notes": """Jocelyn. Four items, each one traceable to something earlier in the presentation rather than invented for this slide. Say that: 'every one of these came out of the last forty minutes.'

That is what makes a future-scope slide credible instead of filler.

Then close, briefly: 'We set out to build something that works when the network doesn't. It does — you've watched it run in airplane mode. Thank you. We'd like to take questions.'

Then EVERYONE comes to the front.""",
    },
    {
        "kind": 'closing', "n": 38,
        "notes": """Everyone comes to the front for questions — it reads as a team and it means the right person can answer.

Jocelyn fields the question and routes it: 'that's Elijah's area.' Nobody answers a question outside their segment unless routed to.

If nobody asks anything, offer one: 'A question we get asked a lot is how far a message actually travels — Thrishen, do you want to take that?'

NEVER say 'I don't know.' Say 'we haven't tested that — here's what we do know.'""",
    },
]

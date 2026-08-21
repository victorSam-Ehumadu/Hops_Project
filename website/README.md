# Hops Website

Static marketing site — four plain HTML pages (`index.html`, `about.html`,
`download.html`, `shop.html`) sharing one stylesheet (`styles.css`). No
build step, no framework, no backend: every page works by just opening the
file, and hosting it is "put these files somewhere that serves static
files," nothing more.

## Before this goes live

Three placeholders need real values — search each file for `TODO`:

1. **Contact email** (`about.html`) — `contact@hopsapp.example` appears
   twice (the visible link and the `CONTACT_EMAIL` JS constant). Replace
   both with a real support address.
2. **Download links** (`download.html`) — the Android/Windows/Linux
   buttons are `href="#"` placeholders with `aria-disabled="true"`. Point
   them at real APK/build download links (or store listings once those
   exist) and remove `aria-disabled` so they're clickable.
3. **Stripe Payment Links** (`shop.html`) — the three "Support" buttons
   are placeholders. To wire up real ones:
   - Go to the [Stripe Dashboard](https://dashboard.stripe.com) → **Payment
     links** → **New**.
   - Start in **test mode** (toggle top-right) — test-mode links use
     [Stripe's test card numbers](https://docs.stripe.com/testing) and
     move no real money, but the checkout flow itself is the real,
     PCI-compliant one, not a mockup.
   - Create one product/price per tier ($2 / $5 / $10, or whatever you
     want), copy the generated `https://buy.stripe.com/test_...` URL, and
     paste it into that tier's `href`.
   - This requires **no code on Hops' side** — Stripe hosts the entire
     checkout page. That's deliberate: seeing a real payment through
     safely requires a secret key to live somewhere, and a static site has
     nowhere safe to put one. Payment Links sidestep that entirely by
     keeping 100% of the payment logic on Stripe's own servers.
   - When ready for real payments, flip the same links to live mode and
     swap the URLs — everything else about this page stays the same.

## Why the Shop page doesn't grant in-app carrots

This was a deliberate scope decision, not an oversight — see
`client/lib/services/carrot_wallet.dart`'s header comment for the full
reasoning. Short version: making a website purchase show up as in-app
currency needs *some* backend holding a Stripe secret key, since a secret
key can never ship in a distributed app. Rather than build and maintain
that, in-app carrots stay entirely free (earned by playing Hops Hopper and
Hops Wordle) and this page is framed as directly supporting development
instead. If a real payment-to-app sync ever gets built, this page's copy
(and the note box on it) will need updating to match — don't let the two
drift out of sync with each other.

## Deploying

Any static host works — there's nothing here that needs a server runtime.
Simplest options:
- **Netlify / Vercel**: drag-and-drop the `website/` folder in their
  dashboard, or connect this repo and set the build directory to
  `website/` with no build command.
- **GitHub Pages**: point Pages at this folder (or a branch containing
  just its contents).

No environment variables, no secrets, no database — the whole site is
these five files plus `assets/hops_bunny.png`.

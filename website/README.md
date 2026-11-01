# Hops Website

Static marketing site — four plain HTML pages (`index.html`, `about.html`,
`download.html`, `shop.html`) plus a `404.html`, sharing one stylesheet
(`styles.css`). No build step, no framework, no backend: hosting it is
"put these files somewhere that serves static files", nothing more.

> Open the pages over `http://`, not `file://`. Everything works either
> way, but Chrome blocks some behaviour on `file://` URLs, so a quick
> `python -m http.server` from this folder is the easiest way to check a
> change.

## Before this goes live

Search for `TODO` in each file. Two placeholders are left:

1. **Contact email** (`about.html`) — `contact@hopsapp.example` appears
   twice (the visible link and the `CONTACT_EMAIL` JS constant). Replace
   both with a real support address.
2. **Download links** (`download.html`) — the Android button is
   `href="#"`. Point it at a real APK or store listing and remove both
   `aria-disabled="true"` and `tabindex="-1"` so it becomes clickable.

The third placeholder — payments — is covered in its own section below.

## The donation page is in DEMO MODE

`shop.html` currently **simulates** a donation. Nothing is charged,
nothing is sent anywhere, and no card details are requested at any point.
A red banner at the top of the page says so, and the receipt is labelled
"Simulated — not charged" with a `DEMO-` prefixed reference.

Two rules were deliberate when this was built, and both matter if you
change it:

- **The banner stays until the simulation goes.** A payment flow that
  looks real but isn't is how someone ends up believing they've donated
  when they haven't. Remove the banner only in the same change that
  removes the simulation.
- **The page asks for no card number, expiry or CVC — not even fake
  ones.** A form that collects card details and does nothing with them is
  a phishing page by shape, whatever the intent. When a real provider is
  connected, the card fields live on *their* hosted page, never on this
  one.

### Switching the donation page to a real provider

The simulation is deliberately isolated so this is a small change. In
`shop.html`:

1. Delete the `<div class="demo-banner">` block.
2. Delete the `simulatePayment()` function and the `#step-processing` and
   `#step-done` steps.
3. Point the confirm button at the provider's hosted checkout, passing the
   amount that's already collected in `state.amount`.

Whichever provider you choose, prefer a **hosted checkout link** over an
embedded card form. Seeing a real payment through safely requires a secret
key to live somewhere, and a static site has nowhere safe to put one — a
hosted link sidesteps that by keeping all the payment logic on the
provider's own servers, so this site needs no backend and holds no
secrets.

Options worth comparing, since Hops is a South African campus project:

| Provider | Notes |
|---|---|
| **PayFast** / **Yoco** | South African; accept local cards and EFT, settle in ZAR. Usually the right default here. |
| **Stripe Payment Links** | Dashboard → Payment links → New. Start in **test mode**; test-mode links use Stripe's published test card numbers and move no real money, but the checkout itself is the real, PCI-compliant one. Stripe's South African availability is worth confirming before committing. |
| **PayPal** | Widest recognition, simplest to set up, highest fees. |

Whichever you pick, create the link in **test mode first**, click through
it end to end, and only then switch to live credentials.

## Why the Support page doesn't grant in-app carrots

A deliberate scope decision, not an oversight — see
`client/lib/services/carrot_wallet.dart`'s header comment for the full
reasoning. Short version: making a website donation show up as in-app
currency needs *some* backend holding a payment secret key, since a secret
key can never ship inside a distributed app. Rather than build and
maintain that, in-app carrots stay entirely free (earned by playing Hops
Hopper and Hops Wordle) and this page is framed as funding development
instead.

The page says this in a note box, and `about.html`'s FAQ repeats it. If a
real payment-to-app sync is ever built, **both** need updating — don't let
them drift.

## Accuracy

The site makes claims about what the app does, so those claims have to
match the code. A review on **10 October 2026** corrected several that
didn't:

- "No account required" — untrue; `main.dart` routes to the sign-up
  gatekeeper unless a saved token exists.
- "Chats are end-to-end" — untrue, and `mesh_crypto.dart`'s own header
  explicitly says the code shouldn't imply it. The 1:1 RFCOMM transport is
  unencrypted; the BLE fallback is deliberately modest, with no
  authentication and no forward secrecy.
- "One-tap" Emergency Flare — it requires confirmation and a reason, and
  isn't reachable from inside the app at all.
- Windows/Linux desktop downloads — the Bluetooth features are
  Android-only, so a desktop build isn't usable as a safety app. No Linux
  build has ever been produced.

If you change app behaviour, check this site hasn't gone stale with it.

## Deploying

Any static host works — nothing here needs a server runtime.

- **Netlify / Vercel**: drag-and-drop this folder, or connect the repo and
  set the publish directory to `website/` with no build command.
- **GitHub Pages**: point Pages at this folder, or a branch containing
  just its contents.

No environment variables, no secrets, no database.

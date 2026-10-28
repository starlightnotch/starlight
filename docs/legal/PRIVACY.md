# Starlight Privacy Policy

Effective October 28, 2026

Starlight is built so that what you say stays on your Mac. This policy explains, in plain words,
what stays on your Mac, what leaves it and why, and what changes when you have a Starlight account
or Starlight Pro.

## The short version

- Your voice is turned into text on your Mac. Audio is never saved or sent anywhere.
- When you ask Starlight something, the question goes to an AI service to be answered: through
  Starlight's answer service with Pro, straight to the provider with your own OpenRouter, Anthropic
  or OpenAI key, or nowhere with a model running on your Mac in Ollama.
- Starlight's answer service passes your question along and sends the answer back. It doesn't keep
  what you asked or what it said; it keeps a count of your answers.
- Payments are processed by Stripe. Starlight never sees your card number.
- No analytics in the app, no ads, no tracking, and your information is never sold. The website
  counts its visits without cookies (see "This website").
- Everything Starlight keeps on your Mac (meetings, dictations, tasks, memory) stays there, and you
  can delete it any time.

## This website

starlightnotch.com counts its visits with Vercel Web Analytics: which pages are opened, from which
kind of device and country, and where visitors came from. It uses no cookies and doesn't identify
you or follow you to other sites. The app itself has no analytics at all.

## What stays on your Mac

**Audio.** Dictation, Live mode, hold-to-ask and meeting notes use your microphone, and meeting
notes can also use your Mac's sound to hear the other side of a call. Speech is transcribed on your
Mac with on-device models. Audio is processed in memory and never written to disk or sent to anyone.

**What Starlight saves.** These are stored in `~/Library/Application Support/Starlight/` on your Mac
(the folder keeps its original name):

- meeting transcripts and notes
- your dictation history
- your tasks
- things you've asked Starlight to remember

Your settings are kept in Starlight's preferences on your Mac. None of this is uploaded. Delete
single items in Starlight, or remove the folder to delete everything.

**Your voice profile.** If you let Starlight learn your voice, it keeps a voice fingerprint: a short
list of numbers describing how you sound, made from a few seconds of you reading a sentence. The
recording itself is never saved. The fingerprint is stored in
`~/Library/Application Support/Starlight/voice.json`, never leaves your Mac, and is only used to tell
you apart from other people in meetings. Forget it any time in Settings → Meetings.

**Your keys and sign-in.** Your OpenRouter key, keys for extensions you turn on, and your Starlight
sign-in are stored in your Mac's Keychain. Each is only sent to the service it belongs to.

## Your Starlight account

Dictation is free with a Starlight account. Ask, Live mode and meeting notes need Starlight Pro, or
its 3-day trial. Without signing in, Starlight's developer receives nothing about you except what's
listed under "What leaves your Mac" (like an update check).

**What the account holds:** your email address, your name if you give one, how you signed in
(email, Apple or Google), and your plan: whether you're on a trial or subscribed, and when it
renews. Sign-in is run by Clerk; your plan is kept in step by Starlight's backend, which runs on
Convex.

**What it never holds:** your recordings, transcripts, notes, tasks, dictations, memory or voice
profile. Those stay on your Mac.

## Payments

Starlight Pro is a subscription, monthly or yearly, with a 3-day free trial. Payments are handled
by Clerk Billing and processed by Stripe: your card details go straight to Stripe and are never sent
to or stored by Starlight. Starlight receives what it needs to run your plan: that you subscribed,
to which plan, when it renews, and whether a trial is running. Stripe's privacy policy covers what
Stripe does with your payment information.

Receipts and payment records are kept for as long as tax and accounting law requires, even after
you delete your account.

## Included answers

When you use the answers included with Pro, your question goes through Starlight's answer service
on its way to the AI service, instead of going straight there with your own key.

- **What's sent:** your question and the context it needs to answer, the same as with your own key
  (see the table below).
- **What the answer service keeps:** a count of your answers this month, linked to your account, to
  keep within Pro's allowance and stop abuse. It does **not** keep the text of your question or of
  the answer.
- **Who answers:** OpenRouter, which passes the question to the model's provider. Starlight asks
  OpenRouter to route only to providers that don't keep or train on it.

With your own key (OpenRouter, Anthropic or OpenAI), none of this applies: your question goes
straight from your Mac to that provider, under its own terms, and Starlight's developer never
receives it. With Ollama, the model runs on your Mac and nothing leaves it.

## What leaves your Mac, and why

Starlight only sends information when a feature needs it:

| When | What is sent | To whom |
|---|---|---|
| You ask Starlight something (by voice or typing) | Your question and the context it needs to answer, such as the conversation so far, the meeting transcript, or what's on your screen if you ask about it | With your own key: the provider you picked (OpenRouter, Anthropic or OpenAI). With Ollama: nowhere, unless Ollama runs on another computer. With Pro: Starlight's answer service, which passes it to OpenRouter |
| An answer needs the web | The search query | With Pro or your OpenRouter key: OpenRouter's web search. With your Anthropic key: Anthropic's web search. With Search the web from this Mac on: Startpage (or Brave or DuckDuckGo), then the top pages themselves, straight from your Mac |
| An answer is about a place or person | The name, to fetch a picture and summary | Wikipedia |
| A YouTube video is playing | The video's ID, to show its thumbnail | YouTube (i.ytimg.com) |
| Starlight opens for the first time | A download request for the speech, voice and cleanup models, which download by themselves | Hugging Face |
| Starlight checks for updates | The app's version | downloads.starlightnotch.com (Cloudflare) |
| You sign in, start a trial or subscribe | Your email and sign-in details; payment details | Clerk (accounts and billing); Stripe (payments); Convex (your plan) |
| You turn on an extension (like Notion) and use it | What that action needs, such as a page you asked to create | That service, using your key |

## Who we work with

| Service | What for | What it receives |
|---|---|---|
| Clerk | Accounts, sign-in and billing | Email, name, sign-in method, plan |
| Stripe | Card payments | Payment details, billing country, email |
| Convex | Starlight's backend: your plan and trial, and the answer service | Your account ID and plan; questions passing through, as above |
| Vercel | Runs starlightnotch.com, and counts its visits (Vercel Web Analytics) | Ordinary web requests; page visits, without cookies |
| Cloudflare | Hosts downloads and updates | The update check |
| OpenRouter | Answers with Pro | Your question and its context |
| Hugging Face | Hosts the on-device models | A download request |

Each handles information under its own privacy policy and only for the purpose listed.

## How long things are kept

- On your Mac: until you delete it.
- Your account, plan and answer counts: while you have an account. Deleting your account removes
  them within 30 days.
- Payment records: as long as tax and accounting law requires.

## Your choices

- **See, change or delete your account** at starlightnotch.com/account (Settings → Account opens
  it), or by writing to us. Deleting your account doesn't touch what's on your Mac.
- **Cancel Pro** any time from the same page; it runs until the end of the period you paid for.

Depending on where you live (for example in the EU, UK or California), you have the right to
access, correct, delete or export your information, and to object to how it's used. Write to us and
we'll answer within 30 days. You can also complain to your local data protection authority.

## Permissions

macOS asks before Starlight can use these. Each is used only for the feature listed:

- **Microphone**: dictation, asking, and your side of meetings
- **System audio recording**: the other side of meetings
- **Accessibility**: pasting into text fields, hearing the key you hold to ask, and reading text on
  screen when you ask
- **Screen Recording**: reading apps that draw their own text, when you ask
- **Automation**: showing and controlling what's playing, and actions you ask for in other apps
- **Reminders**: adding to-dos when you ask
- **Bluetooth**: your headphones' battery, and turning Bluetooth on or off when you ask

You can turn any of these off in System Settings → Privacy & Security.

## Things Starlight never does

- sell, rent or share your information for advertising
- use your recordings, transcripts or questions to train AI models
- keep the text of your questions or answers on its servers
- show ads or track you across apps and websites
- keep recordings of your voice

## Security

Everything Starlight sends travels over encrypted connections. Keys and your sign-in are kept in the
macOS Keychain. Starlight's servers keep as little as they can. If something ever goes wrong with
information we hold, we'll tell you without delay.

## Children

Starlight isn't directed at children under 13 (or the minimum age where you live) and doesn't
knowingly collect their information. Subscriptions are for adults.

## Changes

If this policy changes, the new version is posted with a new effective date. If a change affects
what's collected from your account, we'll tell you in the app or by email before it takes effect.

## Contact

Questions about privacy, or a request about your information: support@starlightnotch.com

Starlight is made by A2 Squared LLC.

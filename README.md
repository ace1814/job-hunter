# Shortlist

A personal, privacy-first job hunting command center for macOS. It pulls jobs from open APIs
and RSS, scores them with a small AI model, flags where you know someone, and keeps you at 10
good applications a day. Your data lives on this Mac. It never auto-submits: Apply opens the job in your browser.

## Build

```sh
make test   # core logic, headless
make run    # builds Shortlist.app and opens it
```

Needs macOS 26 and Xcode 26. The database lives at
`~/Library/Application Support/Shortlist/shortlist.sqlite`.

## Layout

- `Sources/ShortlistCore`: database, records, CSV import, company matching, feeds, scoring. No UI,
  fully tested.
- `Sources/Shortlist`: the SwiftUI app.
- `Tests/ShortlistCoreTests`: tests and CSV fixtures.

## Roadmap

1. Foundation: database, connections import, referral matching ✅
2. Sources: Greenhouse, Lever, Ashby, SmartRecruiters boards; Remotive, RemoteOK, Himalayas, HN; RSS ✅
3. Scoring with `gpt-6-luna` (Ollama as the offline option), the Profile screen, the daily top 15,
   and the model check ✅
4. Dashboard: Today split view, job detail, rationale, referral flags, X/10 count ✅
5. Tailoring with OpenAI and a PDF resume
6. Progress tracker, streaks, morning refresh
7. Web access: a small web server in the app serves the dashboard to any browser, reached
   privately over Tailscale. The Mac stays the engine, and nothing is hosted in the cloud.

## Your network's job boards

Connect Boards on the Sources screen checks every company in your connections for a public
Greenhouse, Lever, Ashby or SmartRecruiters board, a few at a time, starting with where you know the
most people. It only connects a board it can confirm is that company's: the board's own name must
match, or for boards with no name, its postings must talk about the company as themselves.
Stopping keeps what it found, and connecting again carries on. Each company is rechecked after 30
days. Companies with their own careers sites, like Google or Microsoft, have no such board.

## Scoring

The model answers small questions on a 0–4 scale (role, experience, level, location, must-haves)
and the app works out the 0–100 score in `Rubric`, so scores mean the same across models. A wrong
role or place caps a job at 40, and a dealbreaker caps it at 20. Today's list takes the top 15 at
50 or above, and stays in place once picked.

What leaves this Mac when you use OpenAI: each job, your profile and your resume text, sent with
`store: false`. Your name, email, phone and links are left out of scoring. Importing a resume sends
the file's text, with your email and phone taken out first. With Ollama, nothing leaves.

Your key goes in the Keychain from the Profile screen. Model names are settings, not code.

To compare models, label jobs Yes, Maybe or No in All Jobs, then use Model check on the Profile
screen. It shows how often the model ranks jobs the way you do, and leaves saved scores alone.

## Checking the live feeds

The tests use saved copies of each API's real response. To check the live APIs (it uses a
throwaway database, never your real one):

```sh
SHORTLIST_LIVE=1 swift test --filter LiveFeedTests
```

Set `OPENAI_API_KEY` as well to make one real scoring call. Without it, that test is skipped.

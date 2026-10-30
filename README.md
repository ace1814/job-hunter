# Shortlist

A personal, privacy-first job hunting command center for macOS. It pulls jobs from open APIs
and RSS, scores them on this Mac with a local model, flags where you know someone, and keeps you
at 10 good applications a day. It never auto-submits: Apply opens the job in your browser.

## Build

```sh
make test   # core logic, headless
make run    # builds Shortlist.app and opens it
```

Needs macOS 26 and Xcode 26. The database lives at
`~/Library/Application Support/Shortlist/shortlist.sqlite`.

## Layout

- `Sources/ShortlistCore`: database, records, CSV import, company matching. No UI, fully tested.
- `Sources/Shortlist`: the SwiftUI app.
- `Tests/ShortlistCoreTests`: tests and CSV fixtures.

## Roadmap

1. Foundation: database, connections import, referral matching ✅
2. Sources: Greenhouse, Lever, Ashby, SmartRecruiters boards; Remotive, RemoteOK, Himalayas, HN; RSS ✅
3. Local scoring with Ollama (Qwen3 8B) and the daily top 15
4. Dashboard: split view, job detail, rationale, referral flags
5. Tailoring with OpenAI and a PDF resume
6. Progress tracker, streaks, morning refresh
7. Web access: a small web server in the app serves the dashboard to any browser, reached
   privately over Tailscale. The Mac stays the engine, and nothing is hosted in the cloud.

## Checking the live feeds

The tests use saved copies of each API's real response. To check the live APIs (it uses a
throwaway database, never your real one):

```sh
SHORTLIST_LIVE=1 swift test --filter LiveFeedTests
```

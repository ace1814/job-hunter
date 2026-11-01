# Shortlist

A personal, privacy-first job hunting command center for macOS. It pulls jobs from open APIs
and RSS, scores them with a small AI model, flags where you know someone, and keeps you at 10
good applications a day. Your data lives on this Mac. It never auto-submits: Apply opens the job in
your browser, and pressing Submit is always yours.

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
- `Extension`: the Chrome and Brave extension that fills in application forms.

## Roadmap

1. Foundation: database, connections import, referral matching ✅
2. Sources: Greenhouse, Lever, Ashby, SmartRecruiters boards; Remotive, RemoteOK, Himalayas, HN; RSS ✅
3. Scoring with `gpt-6-luna` (Ollama as the offline option), the Profile screen, the daily top 15,
   and the model check ✅
4. Dashboard: Today split view, job detail, rationale, referral flags, X/10 count ✅
5. Tailoring with `gpt-6.1-sol`, a PDF resume, and assisted apply through a browser extension ✅
6. Progress screen, streaks, morning refresh ✅
7. Web access: a small web server in the app serves the dashboard to your own devices over
   Tailscale. The Mac stays the engine, and nothing is hosted in the cloud ✅
8. Freelance: a section of its own, contract searches, Jobicy and Reddit, pitches for posts with no
   form, and proposals counted apart from your daily target ✅

## Applying

Prepare Application writes a resume and answers for one job. Employers, titles and dates are copied
from your master resume by the app. A reworded bullet that adds a number goes back to your original
words, and skills you don't have are dropped. Materials and the PDF stay in
`~/Library/Application Support/Shortlist/Applications`.

Apply opens the posting in your browser. On Greenhouse, Lever, Ashby and SmartRecruiters forms the
extension offers to fill them from those materials. Many jobs come through a board like Himalayas
that sends you on to the real form. Shortlist remembers the job you pressed Apply on for an hour and
asks you to confirm the form is for it. On any other site, click the extension's icon and press Fill
This Page. It never clicks Submit, and it leaves pay, visa and personal background questions for
you. Press I Submitted It to count the application.

Each job also shows who to contact: the people you know there, with design leaders, founders and
recruiters first, and LinkedIn searches for the ones you don't know. Names only ever come from your
connections or from LinkedIn.

To install it, load the `Extension` folder as an unpacked extension, then paste the token from the
Connect screen. The extension talks only to the app on `127.0.0.1:8787`.

## Web access

Turn on web access in Connect, with Tailscale running on this Mac and your other device, then open
the address it shows and sign in with your token. The server listens on this Mac and on its
Tailscale address only, never on your home or office network. It works while the Mac is awake and
Shortlist is open.

## Your network's job boards

Connect Boards on the Sources screen checks every company in your connections for a public
Greenhouse, Lever, Ashby or SmartRecruiters board, a few at a time, starting with where you know the
most people. It only connects a board it can confirm is that company's: the board's own name must
match, or for boards with no name, its postings must talk about the company as themselves.
Stopping keeps what it found, and connecting again carries on. Each company is rechecked after 30
days. Companies with their own careers sites, like Google or Microsoft, have no such board.

## Freelance

Every job is full-time, contract or freelance, from the feed's own label or, failing that, its title.
Contract and freelance work appears under Freelance, with its own top 10 a day, and stays out of
Today and your target. All Jobs hides it unless you turn on its Freelance toggle, and Progress counts
proposals on their own.

Reddit is read from each subreddit's public RSS feed, without an account. Only posts tagged `[Hiring]`
are kept, and they still have to pass your title keywords and `Eligibility`. Reddit allows about one
request a minute, so subreddits are fetched one at a time, last, and at most every 3 hours. Posts
older than 14 days aren't picked, because a filled post stays up. Add a subreddit from Sources by
pasting `r/name`.

A Reddit post that offers less than your minimum budget for the whole job, $200 unless you change
it in Profile, is skipped before any model reads it. Rates by the hour, month or piece are left for
scoring to judge.

Freelance scoring swaps in two more questions, pay and how clear the brief is, and poor pay caps a
job at 40. The model also lists scam signs, such as moving the talk to Telegram or asking for unpaid
test work. Any sign caps the job at 20 and shows up on it.

Reddit posts have no form for the extension to fill. Write Pitch drafts a short reply with
`gpt-6.1-sol`. It uses your resume and nothing else, and the app adds your work link afterwards, so
your links never reach the model. Copy Pitch & Open Post puts it on your clipboard and opens the
post. You send it yourself.

## Scoring

The model answers small questions on a 0–4 scale (role, experience, level, location, must-haves)
and the app works out the 0–100 score in `Rubric`, so scores mean the same across models. A wrong
role or place caps a job at 40, and a dealbreaker caps it at 20. A remote job must be open to
someone living where your profile says you live. `Eligibility` checks that with plain rules before
any model is paid to read the job: the location must name that place or a region that includes it,
or name no place at all with nothing in the posting limiting it. Today's list takes the top 15 at 50 or above, and
stays in place once picked, unless you change your profile and score the jobs again.

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

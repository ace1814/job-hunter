/// The web dashboard, one self-contained page. It carries no data: it asks for your token, then
/// reads everything from the API. Job text only ever reaches the page as plain text.
enum WebPage {
    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Shortlist</title>
    <style>
      :root { --bg: #f6f6f4; --card: #fff; --text: #1b1b1a; --muted: #6b6b66; --line: #e4e4df;
              --accent: #0a66ff; --good: #1f8a4c; --warn: #b4690e; color-scheme: light dark; }
      @media (prefers-color-scheme: dark) {
        :root { --bg: #161616; --card: #222; --text: #f1f1ee; --muted: #a3a39d; --line: #333;
                --accent: #5b9bff; --good: #4cc27f; --warn: #e3a34f; }
      }
      * { box-sizing: border-box; }
      body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.45 -apple-system, system-ui, sans-serif; }
      main { max-width: 720px; margin: 0 auto; padding: 20px 16px 48px; }
      h1 { font-size: 20px; margin: 0 0 14px; }
      .count { display: flex; align-items: baseline; gap: 6px; }
      .count b { font-size: 30px; font-variant-numeric: tabular-nums; }
      .count span { color: var(--muted); }
      .pips { display: flex; gap: 4px; margin: 8px 0 20px; }
      .pips i { flex: 1; height: 6px; border-radius: 3px; background: var(--line); }
      .pips i.on { background: var(--good); }
      .job { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 14px; margin-bottom: 10px; }
      .job.done { opacity: .6; }
      .top { display: flex; gap: 10px; align-items: flex-start; }
      .score { min-width: 36px; text-align: center; font-weight: 600; border-radius: 7px; padding: 2px 4px;
               background: var(--line); font-variant-numeric: tabular-nums; }
      .title { font-weight: 600; }
      .meta, .why { color: var(--muted); font-size: 14px; }
      .why { margin: 8px 0 0; color: var(--text); }
      ul { margin: 6px 0 0; padding-left: 18px; font-size: 14px; }
      .good { color: var(--good); } .warn { color: var(--warn); }
      .actions { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px; }
      button, a.button { flex: 1 1 auto; min-height: 40px; padding: 8px 12px; border-radius: 9px; border: 1px solid var(--line);
                         background: transparent; color: var(--text); font: inherit; font-weight: 600; text-align: center;
                         text-decoration: none; cursor: pointer; }
      a.button, button.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
      form { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 16px; }
      input { width: 100%; min-height: 40px; padding: 8px; margin: 10px 0; border-radius: 8px; border: 1px solid var(--line);
              background: var(--bg); color: var(--text); font: inherit; }
      .empty, .error { color: var(--muted); }
      .error { color: var(--warn); margin-bottom: 12px; }
    </style>
    </head>
    <body>
    <main id="app"></main>
    <script>
    const app = document.getElementById("app");
    const stored = { get() { try { return localStorage.getItem("token"); } catch { return null; } },
                     set(v) { try { localStorage.setItem("token", v); } catch {} },
                     clear() { try { localStorage.removeItem("token"); } catch {} } };
    let token = stored.get();

    function el(tag, props = {}, ...children) {
      const node = Object.assign(document.createElement(tag), props);
      node.append(...children.filter((c) => c !== null && c !== undefined));
      return node;
    }

    async function api(path, method = "GET") {
      const response = await fetch(path, { method, headers: { Authorization: `Bearer ${token}` } });
      if (response.status === 401) { stored.clear(); token = null; showSignIn("That token didn't work."); return null; }
      if (!response.ok) throw new Error("Shortlist couldn't do that.");
      return response.json();
    }

    function show(...children) {
      app.replaceChildren(...children.filter(Boolean));
    }

    function showSignIn(message) {
      const input = el("input", { type: "password", placeholder: "Your token", autocomplete: "off", ariaLabel: "Your token" });
      const form = el("form", {}, el("div", { className: "meta", textContent: "Paste the token from the Connect screen in Shortlist on your Mac." }), input,
                      el("button", { type: "submit", className: "primary", textContent: "Sign In" }));
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        token = input.value.trim();
        stored.set(token);
        load();
      });
      show(el("h1", { textContent: "Shortlist" }), message ? el("div", { className: "error", textContent: message }) : null, form);
    }

    function list(items, className) {
      return items.length ? el("ul", { className }, ...items.map((text) => el("li", { textContent: text }))) : null;
    }

    function act(job, action) {
      const button = el("button", { textContent: { applied: "Mark Applied", dismiss: "Not for Me", undo: "Undo" }[action] });
      button.addEventListener("click", async () => {
        button.disabled = true;
        await api(`/api/jobs/${job.id}/${action}`, "POST").catch(() => {});
        load();
      });
      return button;
    }

    function card(job) {
      const safeURL = /^https?:/i.test(job.url) ? job.url : "#";
      const apply = el("a", { className: "button", href: safeURL, target: "_blank", rel: "noopener noreferrer", textContent: "Apply" });
      const actions = job.isWaiting ? [apply, act(job, "applied"), act(job, "dismiss")] : [act(job, "undo")];
      return el("article", { className: job.isWaiting ? "job" : "job done" },
        el("div", { className: "top" },
          el("div", { className: "score", textContent: job.score ?? "–" }),
          el("div", {}, el("div", { className: "title", textContent: job.title }),
             el("div", { className: "meta", textContent: [job.company, job.location].filter(Boolean).join(" · ") }))),
        job.rationale ? el("p", { className: "why", textContent: job.rationale }) : null,
        list(job.strengths, "good"), list(job.gaps, "warn"),
        job.people.length ? el("div", { className: "meta good", textContent: `You know ${job.people.join(", ")}` }) : null,
        el("div", { className: "actions" }, ...actions));
    }

    function render(today) {
      const pips = el("div", { className: "pips" }, ...Array.from({ length: today.target },
        (_, index) => el("i", { className: index < today.submitted ? "on" : "" })));
      const streak = today.streak > 0 ? ` · ${today.streak} day streak` : "";
      const toDo = today.jobs.filter((job) => job.isWaiting);
      const done = today.jobs.filter((job) => !job.isWaiting);
      show(el("h1", { textContent: "Today" }),
        el("div", { className: "count" }, el("b", { textContent: today.submitted }), el("span", { textContent: `of ${today.target} applications${streak}` })),
        pips,
        ...toDo.map(card), ...done.map(card),
        today.jobs.length ? null : el("div", { className: "empty", textContent: "No picks yet. Score your jobs in the Mac app." }));
    }

    async function load() {
      if (!token) return showSignIn();
      try {
        const today = await api("/api/today");
        if (today) render(today);
      } catch (error) {
        show(el("h1", { textContent: "Shortlist" }), el("div", { className: "error", textContent: "Couldn't reach Shortlist. Is your Mac awake?" }));
      }
    }

    load();
    </script>
    </body>
    </html>
    """#
}

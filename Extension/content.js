// Shows a small panel on application pages. Everything happens only when you press its buttons,
// and the page's own text only ever goes in as plain text.
(() => {
  // The popup's Fill This Page can inject this script into a page that already has it.
  if (globalThis.shortlistPanel) return;
  globalThis.shortlistPanel = true;

  let host = null;
  let lastURL = "";

  function panel() {
    if (host) return host.shadowRoot;
    host = document.createElement("div");
    host.style.cssText = "all:initial;position:fixed;right:16px;bottom:16px;z-index:2147483647";
    const root = host.attachShadow({ mode: "open" });
    const style = document.createElement("style");
    style.textContent = `
      .card { width: 280px; box-sizing: border-box; padding: 14px; border-radius: 12px; background: #fff; color: #1a1a1a;
              font: 13px/1.4 -apple-system, system-ui, sans-serif; box-shadow: 0 6px 24px rgba(0,0,0,.22); }
      .title { font-weight: 600; margin-bottom: 4px; }
      .note { color: #555; margin-bottom: 10px; }
      ul { margin: 0 0 10px; padding-left: 18px; color: #555; }
      button { width: 100%; padding: 8px; margin-top: 6px; border: 0; border-radius: 8px; font: inherit; font-weight: 600;
               background: #0a66ff; color: #fff; cursor: pointer; }
      button.quiet { background: #eee; color: #1a1a1a; }
      @media (prefers-color-scheme: dark) {
        .card { background: #2a2a2c; color: #f2f2f2; } .note, ul { color: #bbb; } button.quiet { background: #444; color: #f2f2f2; }
      }`;
    const card = document.createElement("div");
    card.className = "card";
    root.append(style, card);
    (document.body || document.documentElement).append(host);
    return root;
  }

  function show(title, note, buttons = [], list = []) {
    const card = panel().querySelector(".card");
    card.replaceChildren();
    const heading = document.createElement("div");
    heading.className = "title";
    heading.textContent = title;
    const text = document.createElement("div");
    text.className = "note";
    text.textContent = note;
    card.append(heading, text);
    if (list.length) {
      const items = document.createElement("ul");
      for (const entry of list) {
        const item = document.createElement("li");
        item.textContent = entry;
        items.append(item);
      }
      card.append(items);
    }
    for (const { label, action, quiet } of buttons) {
      const button = document.createElement("button");
      button.textContent = label;
      if (quiet) button.className = "quiet";
      button.addEventListener("click", action);
      card.append(button);
    }
  }

  function close() {
    host?.remove();
    host = null;
  }

  function offerFill(packet) {
    const job = `${packet.title} at ${packet.company}`;
    show("Shortlist", packet.isGuess ? `Is this the form for ${job}?` : job, [
      { label: packet.isGuess ? "Yes, Fill It" : "Fill Application", action: () => runFill(packet) },
      { label: "Hide", action: close, quiet: true },
    ]);
  }

  function runFill(packet) {
    const { filled, needsYou } = ShortlistFill.fill(document, packet);
    if (filled.length === 0) {
      show("Nothing to fill here", "Open the application form, then try again.", [
        { label: "Try Again", action: () => runFill(packet) },
        { label: "Hide", action: close, quiet: true },
      ]);
      return;
    }
    const note = needsYou.length
      ? `Filled ${filled.length} fields. These need you:`
      : `Filled ${filled.length} fields. Check them, then submit.`;
    show("Check before you submit", note, [
      { label: "I Submitted It", action: () => markApplied(packet) },
      { label: "Hide", action: close, quiet: true },
    ], needsYou);
  }

  function markApplied(packet) {
    chrome.runtime.sendMessage({ type: "applied", jobId: packet.jobId }, (result) => {
      if (result?.status === 200) {
        show("Counted", `${packet.company} is marked as applied in Shortlist.`, [{ label: "Close", action: close, quiet: true }]);
      } else {
        show("Couldn't reach Shortlist", "Mark it applied in the app instead.", [{ label: "Close", action: close, quiet: true }]);
      }
    });
  }

  // Listings and ad frames have no form to fill. The form can also appear after the page loads.
  function hasForm() {
    return document.querySelectorAll("input:not([type=hidden]), textarea").length >= 3;
  }

  function check() {
    if (location.href === lastURL || !hasForm()) return;
    lastURL = location.href;
    close();
    const url = window !== window.top && document.referrer.includes("gh_jid") ? document.referrer : location.href;
    chrome.runtime.sendMessage({ type: "packet", url }, (result) => {
      if (!result) return;
      if (result.status === 200) {
        offerFill(result.body);
      } else if (result.status === 409) {
        show("Shortlist", "Press Prepare Application for this job in Shortlist, then reload this page.", [
          { label: "Hide", action: close, quiet: true },
        ]);
      } else if (result.status === 401 || result.status === "no-token") {
        show("Shortlist", "Click the extension's icon and paste your token from Shortlist's Connect screen.", [
          { label: "Hide", action: close, quiet: true },
        ]);
      }
      // A posting that isn't in Shortlist, or the app being closed, shows nothing at all.
    });
  }

  check();
  // Ashby and SmartRecruiters change pages without loading a new one.
  setInterval(check, 1500);
})();

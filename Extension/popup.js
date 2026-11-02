const status = document.getElementById("status");

function check() {
  chrome.runtime.sendMessage({ type: "check" }, (result) => {
    if (result?.status === 200) status.textContent = "Connected to Shortlist.";
    else if (result?.status === "offline") status.textContent = "Couldn't reach Shortlist. Is it open?";
    else if (result?.status === "no-token") status.textContent = "";
    else status.textContent = "That token didn't work.";
  });
}

// For forms on sites the extension doesn't open on by itself. It only gets the page you're on,
// and only because you pressed this.
document.getElementById("fill").addEventListener("click", async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  chrome.runtime.sendMessage({ type: "packet", url: tab.url }, async (result) => {
    if (result?.status === 200) {
      await chrome.scripting.executeScript({ target: { tabId: tab.id, allFrames: true }, files: ["fill.js", "content.js"] });
      window.close();
    } else if (result?.status === 404) {
      status.textContent = "Press Apply on a job in Shortlist first.";
    } else if (result?.status === 409) {
      status.textContent = "Press Prepare Application for this job in Shortlist first.";
    } else {
      check();
    }
  });
});

// Runs in the page you're on, only when you press Save to Tracker. It reads what's already on your
// screen and nothing else: no other tabs, and no requests of its own.
function readThisPage() {
  const tags = document.querySelectorAll('title, meta, script[type="application/ld+json"]');
  const main = document.querySelector('.jobs-description__content, [class*="job-description"], [class*="jobDescription"], main, article');
  const chosen = String(window.getSelection() || "");
  return {
    url: location.href,
    head: [...tags].map((tag) => tag.outerHTML).join("\n").slice(0, 400000),
    text: (chosen || main?.innerText || "").slice(0, 20000),
  };
}

const tracker = document.getElementById("tracker");
const field = (name) => document.getElementById(`job-${name}`);
let page = null;

document.getElementById("track").addEventListener("click", async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  let reading;
  try {
    [{ result: reading }] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: readThisPage });
  } catch {
    status.textContent = "Chrome doesn't let extensions read this page.";
    return;
  }
  chrome.runtime.sendMessage({ type: "readPage", page: reading }, (result) => {
    if (result?.status !== 200) {
      check();
      return;
    }
    page = result.body.page;
    field("title").value = page.title;
    field("company").value = page.company;
    field("location").value = page.location;
    tracker.style.display = "block";
    status.textContent = result.body.isTracked ? "This job is already in your Tracker." : "Check these, then save.";
  });
});

tracker.addEventListener("submit", (event) => {
  event.preventDefault();
  const job = {
    ...page,
    title: field("title").value,
    company: field("company").value,
    location: field("location").value,
    note: field("note").value,
  };
  chrome.runtime.sendMessage({ type: "track", job }, (result) => {
    if (result?.status === 200) {
      tracker.style.display = "none";
      status.textContent = `${job.company} is in your Tracker.`;
    } else if (result?.status === 400) {
      status.textContent = "A job needs a title and a company.";
    } else {
      check();
    }
  });
});

document.getElementById("save").addEventListener("click", async () => {
  const input = document.getElementById("token");
  const token = input.value.trim();
  if (token) await chrome.storage.local.set({ token });
  input.value = "";
  check();
});

check();

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

document.getElementById("save").addEventListener("click", async () => {
  const input = document.getElementById("token");
  const token = input.value.trim();
  if (token) await chrome.storage.local.set({ token });
  input.value = "";
  check();
});

check();

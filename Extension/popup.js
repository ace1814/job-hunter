const status = document.getElementById("status");

function check() {
  chrome.runtime.sendMessage({ type: "check" }, (result) => {
    if (result?.status === 200) status.textContent = "Connected to Shortlist.";
    else if (result?.status === "offline") status.textContent = "Couldn't reach Shortlist. Is it open?";
    else if (result?.status === "no-token") status.textContent = "";
    else status.textContent = "That token didn't work.";
  });
}

document.getElementById("save").addEventListener("click", async () => {
  const input = document.getElementById("token");
  const token = input.value.trim();
  if (token) await chrome.storage.local.set({ token });
  input.value = "";
  check();
});

check();

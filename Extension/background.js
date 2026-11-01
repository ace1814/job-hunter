// Talks to the Shortlist app on this Mac. Content scripts run in the job site's page, so the
// token stays here and they only ever see the answers.
const SERVER = "http://127.0.0.1:8787";

async function call(path, method = "GET") {
  const { token } = await chrome.storage.local.get("token");
  if (!token) return { status: "no-token" };
  try {
    const response = await fetch(SERVER + path, { method, headers: { Authorization: `Bearer ${token}` } });
    const body = await response.json();
    return { status: response.status, body };
  } catch {
    return { status: "offline" };
  }
}

chrome.runtime.onMessage.addListener((message, _sender, reply) => {
  if (message.type === "packet") {
    call(`/api/packet?url=${encodeURIComponent(message.url)}`).then(reply);
  } else if (message.type === "applied") {
    call(`/api/jobs/${Number(message.jobId)}/applied`, "POST").then(reply);
  } else if (message.type === "check") {
    call("/api/today").then(reply);
  } else {
    return false;
  }
  return true;
});

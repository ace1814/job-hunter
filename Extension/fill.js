// Fills an application form from a packet. It never clicks anything and never submits: pressing
// Submit is always yours. Questions about pay, visas or who you are stay blank for you to answer.
(() => {
  const NEVER = /salary|compensation|ctc|visa|sponsor|authori[sz]|gender|sex\b|race|ethnic|veteran|disab|pronoun|birth|\bage\b|nationality|citizen|notice period|hispanic|criminal|preferred (first )?name|captcha/i;

  // Checked in order, against the field's name, id and label together. The first hit wins.
  const RULES = [
    [/first.?name|given name/i, "firstName"],
    [/last.?name|surname|family name/i, "lastName"],
    [/e-?mail/i, "email"],
    [/phone|mobile/i, "phone"],
    [/linkedin/i, "linkedIn"],
    [/portfolio|website|personal site|urls\[other\]/i, "portfolio"],
    [/current (company|employer)|^org$|organi[sz]ation/i, "currentCompany"],
    [/location|\bcity\b|where .*(based|located|live|work)/i, "location"],
    [/(^|[^a-z])(full.?)?name($|[^a-z])/i, "name"],
  ];
  const BLURBS = [
    [/why .*(fit|good|right|qualified|strong)|what makes you/i, "Why are you a good fit for this role?"],
    [/why .*(join|work|want|interest|apply|company|us\b)|what (excites|interests|attracts)/i, "Why do you want to work here?"],
    [/cover.?letter/i, "Cover letter"],
  ];

  function labelText(field) {
    const parts = [field.getAttribute("aria-label") || ""];
    if (field.id) {
      const label = field.ownerDocument.querySelector(`label[for="${CSS.escape(field.id)}"]`);
      if (label) parts.push(label.textContent);
    }
    const wrapping = field.closest("label");
    if (wrapping) parts.push(wrapping.textContent);
    for (const id of (field.getAttribute("aria-labelledby") || "").split(/\s+/).filter(Boolean)) {
      const label = field.ownerDocument.getElementById(id);
      if (label) parts.push(label.textContent);
    }
    if (parts.join("").trim() === "") {
      let parent = field.parentElement;
      for (let hops = 0; parent && hops < 3; hops += 1, parent = parent.parentElement) {
        const label = parent.querySelector("label, legend");
        if (label) {
          parts.push(label.textContent);
          break;
        }
      }
    }
    parts.push(field.placeholder || "");
    return parts.join(" ").replace(/\s+/g, " ").trim();
  }

  function isShown(field) {
    const style = field.ownerDocument.defaultView.getComputedStyle(field);
    return style.display !== "none" && style.visibility !== "hidden" && field.getClientRects().length > 0;
  }

  // React and friends watch the native setter, so a plain assignment would be thrown away.
  function setValue(field, value) {
    const proto = field.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, "value").set.call(field, value);
    for (const type of ["input", "change", "blur"]) {
      field.dispatchEvent(new Event(type, { bubbles: true }));
    }
  }

  function attachResume(input, packet) {
    const bytes = Uint8Array.from(atob(packet.resumeBase64), (c) => c.charCodeAt(0));
    const transfer = new DataTransfer();
    transfer.items.add(new File([bytes], packet.resumeName, { type: "application/pdf" }));
    input.files = transfer.files;
    input.dispatchEvent(new Event("input", { bubbles: true }));
    input.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function answerFor(text, field, packet) {
    if (field.tagName === "TEXTAREA") {
      for (const [pattern, question] of BLURBS) {
        if (pattern.test(text)) return packet.blurbs.find((b) => b.question === question)?.answer || "";
      }
      return "";
    }
    for (const [pattern, key] of RULES) {
      if (pattern.test(text)) return packet[key] || "";
    }
    return "";
  }

  function fill(doc, packet) {
    const report = { filled: [], needsYou: [] };

    const files = [...doc.querySelectorAll('input[type="file"]')];
    const resumeInput = files.find((f) => /resume|\bcv\b/i.test(`${f.name} ${f.id} ${labelText(f)}`) && !f.files.length);
    if (resumeInput) {
      attachResume(resumeInput, packet);
      report.filled.push("Resume");
    }

    const fields = doc.querySelectorAll(
      'input[type="text"], input[type="email"], input[type="tel"], input[type="url"], input:not([type]), textarea');
    for (const field of fields) {
      if (field.disabled || field.readOnly || !isShown(field)) continue;
      const label = labelText(field);
      const text = `${label} ${field.name} ${field.id}`;
      const required = field.required || field.getAttribute("aria-required") === "true" || /\*\s*$/.test(label);
      if (NEVER.test(text)) {
        if (required && !field.value) report.needsYou.push(label || field.name);
        continue;
      }
      if (field.value) continue;
      const answer = answerFor(text, field, packet);
      if (answer) {
        setValue(field, answer);
        report.filled.push(label || field.name);
      } else if (required) {
        report.needsYou.push(label || field.name);
      }
    }
    return report;
  }

  globalThis.ShortlistFill = { fill };
})();

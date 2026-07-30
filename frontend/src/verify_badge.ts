import type { Verification } from "./socket.js";

/**
 * On-screen proof that the visuals are being directed by *verifiable* AI.
 *
 * When the Director runs on the 0G Compute Network, every image message carries
 * a receipt: which TEE-sealed model produced the prompt, and whether its
 * cryptographic signature verified. This badge surfaces that live — the thing
 * that separates "an AI made this" from "a *provable* AI made this, on-chain".
 *
 * It's deliberately shown even in performance (`?clean=1`) mode: the projection
 * the audience and judges see is exactly where the proof belongs.
 */
export class VerifyBadge {
  private el: HTMLDivElement;
  private dot: HTMLSpanElement;
  private label: HTMLSpanElement;
  private sub: HTMLSpanElement;

  constructor() {
    const el = document.createElement("div");
    el.className = "verify-badge";
    el.style.cssText = [
      "position:fixed",
      "left:16px",
      "bottom:16px",
      "z-index:9999",
      "display:none",
      "align-items:center",
      "gap:10px",
      "padding:9px 14px 9px 12px",
      "border-radius:999px",
      "font:500 13px/1.2 ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,sans-serif",
      "color:#eafff2",
      "background:rgba(8,20,14,0.62)",
      "backdrop-filter:blur(10px)",
      "-webkit-backdrop-filter:blur(10px)",
      "border:1px solid rgba(64,224,138,0.35)",
      "box-shadow:0 4px 24px rgba(0,0,0,0.35)",
      "letter-spacing:0.01em",
      "user-select:none",
      "transition:opacity .4s ease",
    ].join(";");

    const dot = document.createElement("span");
    dot.style.cssText =
      "width:9px;height:9px;border-radius:50%;flex:0 0 auto;box-shadow:0 0 8px currentColor";

    const text = document.createElement("span");
    text.style.cssText = "display:flex;flex-direction:column;gap:1px";

    const label = document.createElement("span");
    label.style.cssText = "font-weight:650";
    const sub = document.createElement("span");
    sub.style.cssText = "font-size:11px;opacity:0.72;letter-spacing:0.02em";

    text.appendChild(label);
    text.appendChild(sub);
    el.appendChild(dot);
    el.appendChild(text);
    document.body.appendChild(el);

    this.el = el;
    this.dot = dot;
    this.label = label;
    this.sub = sub;
  }

  /** Update from an image message's receipt (undefined = Director not on 0G). */
  update(v: Verification | undefined): void {
    if (!v) {
      // Not produced by 0G this frame (e.g. fell back to local Gemma). Leave the
      // last state up rather than flickering the badge off every non-0G frame.
      return;
    }
    this.el.style.display = "flex";

    const model = short(v.model);
    const provider = shortAddr(v.provider);

    // Three genuinely different states — collapsing false into "pending" left the
    // badge claiming a verification was still coming when it had already failed.
    if (v.verified === true) {
      const green = "#40e08a";
      this.dot.style.color = green;
      this.el.style.borderColor = "rgba(64,224,138,0.45)";
      this.label.textContent = `Verifiable AI · ${model}`;
      this.sub.textContent = `0G Compute · TEE-verified · ${provider}`;
    } else if (v.verified === null || v.verified === undefined) {
      // Settlement is an on-chain round-trip we don't block the show on; this
      // state resolves when the `verification` message arrives.
      const amber = "#e0b040";
      this.dot.style.color = amber;
      this.el.style.borderColor = "rgba(224,176,64,0.4)";
      this.label.textContent = `0G Compute · ${model}`;
      this.sub.textContent = `answer received · verifying on-chain · ${provider}`;
    } else {
      // Settled, but the provider couldn't produce a signature for this response.
      // Say so plainly rather than implying a pending check.
      const slate = "#8fa3b0";
      this.dot.style.color = slate;
      this.el.style.borderColor = "rgba(143,163,176,0.35)";
      this.label.textContent = `0G Compute · ${model}`;
      this.sub.textContent = `answer received · signature unavailable · ${provider}`;
    }
    this.el.title = v.chatId ? `receipt ${v.chatId}` : "";
  }
}

function short(model: string): string {
  if (!model) return "unknown model";
  // Strip an org prefix like "meta-llama/" and keep the model id.
  const id = model.includes("/") ? model.split("/").pop()! : model;
  return id.length > 28 ? id.slice(0, 27) + "…" : id;
}

function shortAddr(addr: string): string {
  return addr && addr.length > 12 ? `${addr.slice(0, 6)}…${addr.slice(-4)}` : addr || "";
}

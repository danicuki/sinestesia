import QRCode from "qrcode";
import type { MintMsg } from "./socket.js";

/**
 * The payoff moment: when a song ends and the painting is stored on Walrus +
 * minted on Sui, this overlay rises over the finished canvas showing a big QR
 * the room scans to claim their own free print — plus the provenance hash and
 * rarity that prove the token is that exact live performance, not just an image.
 *
 * Self-contained: QR is rendered locally (bundled `qrcode`, no network), so it
 * works on the projection even with a flaky venue connection.
 */
export class MintOverlay {
  private root: HTMLDivElement;
  private card: HTMLDivElement;

  constructor() {
    const root = document.createElement("div");
    root.style.cssText = [
      "position:fixed",
      "inset:0",
      "z-index:10000",
      "display:none",
      "align-items:center",
      "justify-content:center",
      "background:rgba(4,10,7,0.72)",
      "backdrop-filter:blur(6px)",
      "-webkit-backdrop-filter:blur(6px)",
      "font:15px/1.5 ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,sans-serif",
      "color:#eafff2",
    ].join(";");

    const card = document.createElement("div");
    card.style.cssText = [
      "max-width:min(90vw,420px)",
      "padding:26px 28px 22px",
      "border-radius:20px",
      "text-align:center",
      "background:rgba(10,22,15,0.92)",
      "border:1px solid rgba(64,224,138,0.35)",
      "box-shadow:0 18px 60px rgba(0,0,0,0.5)",
    ].join(";");

    root.appendChild(card);
    root.addEventListener("click", (e) => {
      if (e.target === root) this.hide(); // click the backdrop to dismiss
    });
    document.body.appendChild(root);
    this.root = root;
    this.card = card;
  }

  /** In-flight: chain + Walrus can take a few seconds. */
  showMinting(): void {
    this.card.innerHTML = `
      <div style="font-size:19px;font-weight:650;margin-bottom:6px">Minting the painting…</div>
      <div style="opacity:.7;font-size:14px">Storing on Walrus · minting on Sui</div>
      <div class="mint-spin" style="margin:20px auto 4px;width:34px;height:34px;border-radius:50%;
        border:3px solid rgba(64,224,138,.25);border-top-color:#40e08a;animation:mintspin 1s linear infinite"></div>`;
    this.ensureKeyframes();
    this.reveal();
  }

  showError(message: string): void {
    this.card.innerHTML = `
      <div style="font-size:18px;font-weight:650;margin-bottom:8px">Mint didn't go through</div>
      <div style="opacity:.8;font-size:14px;word-break:break-word">${escapeHtml(message)}</div>
      <button class="mint-close" style="margin-top:18px;padding:10px 20px;border-radius:999px;
        border:1px solid rgba(255,255,255,.25);background:transparent;color:#eafff2;cursor:pointer">Close</button>`;
    this.card.querySelector(".mint-close")?.addEventListener("click", () => this.hide());
    this.reveal();
  }

  /** The finished mint: QR to claim, provenance, rarity, explorer link. */
  async showResult(m: MintMsg): Promise<void> {
    const rarity = m.traits && typeof m.traits.rarity === "string" ? m.traits.rarity : undefined;
    const proof = m.provenanceHash ? `${m.provenanceHash.slice(0, 10)}…` : undefined;
    const claim = m.claimUrl ?? m.explorerUrl ?? "";

    this.card.innerHTML = `
      <div style="font-size:20px;font-weight:700;letter-spacing:.01em">Minted live on Sui</div>
      ${rarity ? `<div style="margin-top:4px;font-size:13px;text-transform:uppercase;letter-spacing:.12em;color:#40e08a">${escapeHtml(rarity)}</div>` : ""}
      <div class="mint-qr" style="margin:18px auto 12px;width:232px;height:232px;background:#fff;border-radius:14px;padding:12px;box-sizing:border-box"></div>
      <div style="font-size:15px;font-weight:600">Scan to claim your free print</div>
      <div style="margin-top:10px;font-size:12px;opacity:.62;line-height:1.6">
        ${proof ? `provenance <span style="font-family:ui-monospace,monospace">${escapeHtml(proof)}</span><br>` : ""}
        ${m.explorerUrl ? `<a href="${escapeAttr(m.explorerUrl)}" target="_blank" style="color:#40e08a">view the release on-chain →</a>` : ""}
      </div>
      <button class="mint-close" style="margin-top:16px;padding:9px 20px;border-radius:999px;
        border:1px solid rgba(255,255,255,.22);background:transparent;color:#eafff2;cursor:pointer;font-size:13px">Close</button>`;

    this.card.querySelector(".mint-close")?.addEventListener("click", () => this.hide());
    this.reveal();

    const holder = this.card.querySelector(".mint-qr") as HTMLDivElement | null;
    if (holder && claim) {
      const canvas = document.createElement("canvas");
      holder.appendChild(canvas);
      try {
        await QRCode.toCanvas(canvas, claim, { width: 208, margin: 0 });
      } catch {
        holder.textContent = claim; // extremely unlikely; degrade to the raw URL
        holder.style.cssText += ";color:#000;font-size:11px;word-break:break-all";
      }
    }
  }

  hide(): void {
    this.root.style.display = "none";
  }

  private reveal(): void {
    this.root.style.display = "flex";
  }

  private ensureKeyframes(): void {
    if (document.getElementById("mint-keyframes")) return;
    const s = document.createElement("style");
    s.id = "mint-keyframes";
    s.textContent = "@keyframes mintspin{to{transform:rotate(360deg)}}";
    document.head.appendChild(s);
  }
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c] ?? c);
}
function escapeAttr(s: string): string {
  return escapeHtml(s).replace(/"/g, "&quot;");
}

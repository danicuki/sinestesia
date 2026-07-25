import QRCode from "qrcode";
import type { MintMsg } from "./socket.js";

/**
 * The payoff moment, in the corner: when a song ends, the painting is stored on
 * Walrus and minted on Sui, and the room gets a QR to claim a print of it.
 *
 * Deliberately NOT a modal. Ending a song also starts the next one — the singer
 * is already singing and the canvas is already painting again — so covering the
 * screen would hide the show to advertise the show. It sits bottom-right,
 * spinner while minting, QR + title once it lands, and stays until dismissed or
 * replaced by the next song's mint.
 *
 * Self-contained: the QR is rendered locally (bundled `qrcode`, no network), so
 * it works on the projection even with a flaky venue connection.
 */
export class MintToast {
  private root: HTMLDivElement;

  constructor() {
    const root = document.createElement("div");
    root.style.cssText = [
      "position:fixed",
      "right:16px",
      "bottom:16px",
      "z-index:10000",
      "display:none",
      "max-width:260px",
      "padding:14px 16px",
      "border-radius:14px",
      "background:rgba(10,22,15,0.9)",
      "border:1px solid rgba(64,224,138,0.35)",
      "box-shadow:0 10px 34px rgba(0,0,0,0.45)",
      "backdrop-filter:blur(8px)",
      "-webkit-backdrop-filter:blur(8px)",
      "font:13px/1.5 ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,sans-serif",
      "color:#eafff2",
      "transition:opacity .25s ease",
    ].join(";");
    document.body.appendChild(root);
    this.root = root;
  }

  /** In-flight: Walrus + chain can take a few seconds. */
  showMinting(): void {
    this.root.innerHTML = `
      <div style="display:flex;align-items:center;gap:10px">
        <div style="width:16px;height:16px;flex:0 0 auto;border-radius:50%;
          border:2px solid rgba(64,224,138,.25);border-top-color:#40e08a;
          animation:mintspin 1s linear infinite"></div>
        <div>
          <div style="font-weight:600">Minting the last song…</div>
          <div style="opacity:.62;font-size:12px">Walrus · Sui</div>
        </div>
      </div>`;
    this.ensureKeyframes();
    this.reveal();
  }

  showError(message: string): void {
    this.root.innerHTML = `
      <div style="font-weight:600;margin-bottom:4px">Mint didn't go through</div>
      <div style="opacity:.75;font-size:12px;word-break:break-word">${escapeHtml(message)}</div>`;
    this.appendClose();
    this.reveal();
  }

  /** The finished mint: QR to claim, song title, link to the release on-chain. */
  async showResult(m: MintMsg): Promise<void> {
    const claim = m.claimUrl ?? m.explorerUrl ?? "";
    const title = m.song?.trim();
    const artist = m.artist?.trim();

    this.root.innerHTML = `
      <div style="font-size:11px;text-transform:uppercase;letter-spacing:.12em;color:#40e08a">
        Minted on Sui
      </div>
      ${
        title
          ? `<div style="margin-top:5px;font-weight:650;font-size:14px;line-height:1.3">${
              m.explorerUrl
                ? `<a href="${escapeAttr(m.explorerUrl)}" target="_blank"
                     style="color:#eafff2;text-decoration:none;border-bottom:1px solid rgba(64,224,138,.5)"
                     >${escapeHtml(title)}</a>`
                : escapeHtml(title)
            }</div>`
          : ""
      }
      ${artist ? `<div style="opacity:.6;font-size:12px">${escapeHtml(artist)}</div>` : ""}
      <div class="mint-qr" style="margin:10px 0 8px;width:148px;height:148px;
        background:#fff;border-radius:10px;padding:8px;box-sizing:border-box"></div>
      <div style="font-size:12px;opacity:.8">Scan to claim your free print</div>`;
    this.appendClose();
    this.reveal();

    const holder = this.root.querySelector(".mint-qr") as HTMLDivElement | null;
    if (holder && claim) {
      const canvas = document.createElement("canvas");
      holder.appendChild(canvas);
      try {
        await QRCode.toCanvas(canvas, claim, { width: 132, margin: 0 });
      } catch {
        holder.textContent = claim; // extremely unlikely; degrade to the raw URL
        holder.style.cssText += ";color:#000;font-size:10px;word-break:break-all";
      }
    }
  }

  hide(): void {
    this.root.style.display = "none";
  }

  /** Small × in the corner — the toast never steals focus or blocks the canvas. */
  private appendClose(): void {
    const close = document.createElement("button");
    close.textContent = "×";
    close.title = "Dismiss";
    close.style.cssText = [
      "position:absolute",
      "top:6px",
      "right:8px",
      "border:0",
      "background:transparent",
      "color:#eafff2",
      "opacity:.45",
      "font:16px/1 ui-sans-serif,system-ui,sans-serif",
      "cursor:pointer",
      "padding:2px 4px",
    ].join(";");
    close.addEventListener("click", () => this.hide());
    this.root.appendChild(close);
  }

  private reveal(): void {
    this.root.style.display = "block";
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

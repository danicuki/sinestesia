/**
 * High-end Glassmorphic Floating Audio Player for Sinestesia.
 * Synchronizes a HTMLAudioElement playhead with WebGL scene rendering.
 */

const STYLE_ID = "sinestesia-audio-player-styles";

function formatTime(secs: number): string {
  if (isNaN(secs) || !isFinite(secs)) return "00:00";
  const m = Math.floor(secs / 60);
  const s = Math.floor(secs % 60);
  return `${m.toString().padStart(2, "0")}:${s.toString().padStart(2, "0")}`;
}

export class AudioPlayerUI {
  private audio: HTMLAudioElement;
  private container: HTMLDivElement | null = null;
  private playBtn: HTMLButtonElement | null = null;
  private seekFill: HTMLDivElement | null = null;
  private seekThumb: HTMLDivElement | null = null;
  private seekContainer: HTMLDivElement | null = null;
  private timeLabel: HTMLSpanElement | null = null;
  private volumeBtn: HTMLButtonElement | null = null;

  private onPlayheadUpdate: (timeMs: number) => void;
  private isDragging = false;
  private isMuted = false;

  constructor(audioUrl: string, onPlayheadUpdate: (timeMs: number) => void) {
    this.onPlayheadUpdate = onPlayheadUpdate;

    this.audio = new Audio();
    this.audio.src = audioUrl;
    this.audio.preload = "auto";

    this.injectStyles();
    this.buildUI();
    this.attachEvents();
  }

  public get durationMs(): number {
    return (this.audio.duration || 0) * 1000;
  }

  public get currentTimeMs(): number {
    return this.audio.currentTime * 1000;
  }

  public play() {
    this.audio.play().catch((err) => {
      console.warn("[audio] auto-play block or failure:", err);
    });
    this.updatePlayState();
  }

  public pause() {
    this.audio.pause();
    this.updatePlayState();
  }

  public seekTo(timeMs: number) {
    const secs = timeMs / 1000;
    this.audio.currentTime = Math.max(0, Math.min(secs, this.audio.duration || 0));
    this.updatePlayhead();
    this.onPlayheadUpdate(this.currentTimeMs);
  }

  public destroy() {
    this.pause();
    this.audio.src = "";
    this.audio.load();

    if (this.container && this.container.parentNode) {
      this.container.parentNode.removeChild(this.container);
    }
    this.container = null;
  }

  private injectStyles() {
    if (document.getElementById(STYLE_ID)) return;

    const style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = `
      .sinestesia-audio-player {
        position: fixed;
        bottom: 24px;
        left: 50%;
        transform: translateX(-50%);
        width: calc(100% - 48px);
        max-width: 520px;
        height: 64px;
        background: rgba(13, 11, 20, 0.72);
        backdrop-filter: blur(20px) saturate(180%);
        -webkit-backdrop-filter: blur(20px) saturate(180%);
        border: 1px solid rgba(255, 255, 255, 0.08);
        border-radius: 32px;
        box-shadow: 0 10px 40px rgba(0, 0, 0, 0.55), inset 0 1px 0 rgba(255, 255, 255, 0.1);
        display: flex;
        align-items: center;
        padding: 0 20px 0 12px;
        gap: 16px;
        z-index: 1000;
        box-sizing: border-box;
        font-family: 'Outfit', 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
        user-select: none;
        transition: transform 0.4s cubic-bezier(0.16, 1, 0.3, 1), opacity 0.4s cubic-bezier(0.16, 1, 0.3, 1);
      }

      .sinestesia-audio-player.hidden {
        transform: translate(-50%, 100px);
        opacity: 0;
        pointer-events: none;
      }

      .sinestesia-play-btn {
        width: 44px;
        height: 44px;
        border-radius: 50%;
        border: none;
        background: linear-gradient(135deg, #a855f7, #ec4899);
        display: flex;
        align-items: center;
        justify-content: center;
        cursor: pointer;
        box-shadow: 0 4px 14px rgba(236, 72, 153, 0.45);
        transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
        padding: 0;
        flex-shrink: 0;
        outline: none;
      }

      .sinestesia-play-btn:hover {
        transform: scale(1.06);
        box-shadow: 0 6px 18px rgba(236, 72, 153, 0.65);
      }

      .sinestesia-play-btn:active {
        transform: scale(0.94);
      }

      .sinestesia-play-btn svg {
        width: 16px;
        height: 16px;
        fill: white;
        transition: transform 0.15s ease;
      }

      .sinestesia-time-info {
        font-size: 13px;
        font-weight: 500;
        color: rgba(255, 255, 255, 0.85);
        min-width: 80px;
        text-align: center;
        font-variant-numeric: tabular-nums;
        flex-shrink: 0;
        letter-spacing: -0.2px;
      }

      .sinestesia-seekbar-container {
        flex-grow: 1;
        height: 24px;
        display: flex;
        align-items: center;
        cursor: pointer;
        position: relative;
      }

      .sinestesia-seekbar-bg {
        width: 100%;
        height: 6px;
        background: rgba(255, 255, 255, 0.12);
        border-radius: 3px;
        position: relative;
      }

      .sinestesia-seekbar-fill {
        height: 100%;
        width: 0%;
        background: linear-gradient(90deg, #9333ea, #db2777);
        border-radius: 3px;
        position: absolute;
        left: 0;
        top: 0;
        pointer-events: none;
      }

      .sinestesia-seekbar-thumb {
        width: 12px;
        height: 12px;
        border-radius: 50%;
        background: white;
        position: absolute;
        left: 0%;
        top: 50%;
        transform: translate(-50%, -50%) scale(0);
        box-shadow: 0 2px 6px rgba(0, 0, 0, 0.5);
        transition: transform 0.15s cubic-bezier(0.16, 1, 0.3, 1);
        pointer-events: none;
      }

      .sinestesia-seekbar-container:hover .sinestesia-seekbar-thumb,
      .sinestesia-seekbar-container.dragging .sinestesia-seekbar-thumb {
        transform: translate(-50%, -50%) scale(1.3);
      }

      .sinestesia-volume-btn {
        background: transparent;
        border: none;
        cursor: pointer;
        width: 32px;
        height: 32px;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 0;
        border-radius: 50%;
        transition: background-color 0.2s ease, transform 0.2s ease;
        flex-shrink: 0;
        outline: none;
      }

      .sinestesia-volume-btn:hover {
        background-color: rgba(255, 255, 255, 0.08);
        transform: scale(1.05);
      }

      .sinestesia-volume-btn:active {
        transform: scale(0.95);
      }

      .sinestesia-volume-btn svg {
        width: 18px;
        height: 18px;
        fill: rgba(255, 255, 255, 0.8);
      }
    `;
    document.head.appendChild(style);
  }

  private buildUI() {
    const div = document.createElement("div");
    div.className = "sinestesia-audio-player";

    // Play/Pause circular button
    const playBtn = document.createElement("button");
    playBtn.className = "sinestesia-play-btn";
    playBtn.innerHTML = this.getPlayIcon();

    // Time text label
    const timeLabel = document.createElement("span");
    timeLabel.className = "sinestesia-time-info";
    timeLabel.textContent = "00:00 / 00:00";

    // Seek bar container
    const seekContainer = document.createElement("div");
    seekContainer.className = "sinestesia-seekbar-container";

    const seekBg = document.createElement("div");
    seekBg.className = "sinestesia-seekbar-bg";

    const seekFill = document.createElement("div");
    seekFill.className = "sinestesia-seekbar-fill";

    const seekThumb = document.createElement("div");
    seekThumb.className = "sinestesia-seekbar-thumb";

    seekBg.appendChild(seekFill);
    seekBg.appendChild(seekThumb);
    seekContainer.appendChild(seekBg);

    // Mute/Unmute button
    const volumeBtn = document.createElement("button");
    volumeBtn.className = "sinestesia-volume-btn";
    volumeBtn.innerHTML = this.getVolumeIcon();

    div.appendChild(playBtn);
    div.appendChild(timeLabel);
    div.appendChild(seekContainer);
    div.appendChild(volumeBtn);

    document.body.appendChild(div);

    this.container = div;
    this.playBtn = playBtn;
    this.seekFill = seekFill;
    this.seekThumb = seekThumb;
    this.seekContainer = seekContainer;
    this.timeLabel = timeLabel;
    this.volumeBtn = volumeBtn;
  }

  private attachEvents() {
    this.playBtn?.addEventListener("click", () => {
      if (this.audio.paused) {
        this.play();
      } else {
        this.pause();
      }
    });

    this.volumeBtn?.addEventListener("click", () => {
      this.isMuted = !this.isMuted;
      this.audio.muted = this.isMuted;
      this.volumeBtn!.innerHTML = this.isMuted ? this.getMutedIcon() : this.getVolumeIcon();
    });

    this.audio.addEventListener("timeupdate", () => {
      if (!this.isDragging) {
        this.updatePlayhead();
        this.onPlayheadUpdate(this.currentTimeMs);
      }
    });

    this.audio.addEventListener("loadedmetadata", () => {
      this.updatePlayhead();
    });

    this.audio.addEventListener("ended", () => {
      this.updatePlayState();
    });

    // Seekbar dragging/clicking logic
    const handleSeek = (e: MouseEvent) => {
      if (!this.seekContainer || !this.audio.duration) return;
      const rect = this.seekContainer.getBoundingClientRect();
      const pct = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
      this.audio.currentTime = pct * this.audio.duration;
      this.updatePlayhead();
      this.onPlayheadUpdate(this.currentTimeMs);
    };

    this.seekContainer?.addEventListener("mousedown", (e) => {
      this.isDragging = true;
      this.seekContainer?.classList.add("dragging");
      handleSeek(e);

      const moveHandler = (moveEv: MouseEvent) => {
        handleSeek(moveEv);
      };

      const upHandler = () => {
        this.isDragging = false;
        this.seekContainer?.classList.remove("dragging");
        window.removeEventListener("mousemove", moveHandler);
        window.removeEventListener("mouseup", upHandler);
      };

      window.addEventListener("mousemove", moveHandler);
      window.addEventListener("mouseup", upHandler);
    });
  }

  private updatePlayhead() {
    const cur = this.audio.currentTime || 0;
    const dur = this.audio.duration || 0;
    const pct = dur > 0 ? (cur / dur) * 100 : 0;

    if (this.seekFill) this.seekFill.style.width = `${pct}%`;
    if (this.seekThumb) this.seekThumb.style.left = `${pct}%`;
    if (this.timeLabel) {
      this.timeLabel.textContent = `${formatTime(cur)} / ${formatTime(dur)}`;
    }
  }

  private updatePlayState() {
    if (!this.playBtn) return;
    if (this.audio.paused) {
      this.playBtn.innerHTML = this.getPlayIcon();
    } else {
      this.playBtn.innerHTML = this.getPauseIcon();
    }
  }

  private getPlayIcon() {
    return `<svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>`;
  }

  private getPauseIcon() {
    return `<svg viewBox="0 0 24 24"><path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z"/></svg>`;
  }

  private getVolumeIcon() {
    return `<svg viewBox="0 0 24 24"><path d="M3 9v6h4l7 7V3L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z"/></svg>`;
  }

  private getMutedIcon() {
    return `<svg viewBox="0 0 24 24"><path d="M16.5 12c0-1.77-1.02-3.29-2.5-4.03v2.21l2.45 2.45c.03-.21.05-.42.05-.63zm2.5 0c0 .94-.2 1.82-.54 2.64l1.51 1.51C20.63 14.91 21 13.5 21 12c0-4.28-2.99-7.86-7-8.77v2.06c2.89.86 5 3.54 5 6.71zM4.27 3L3 4.27 7.73 9H3v6h4l7 7v-6.73l4.25 4.25c-.67.52-1.42.93-2.25 1.18v2.06c1.38-.31 2.63-.95 3.69-1.81L19.73 21 21 19.73l-9-9L4.27 3zM12 4L9.91 6.09 12 8.18V4z"/></svg>`;
  }
}

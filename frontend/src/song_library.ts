import { mountInDock, panelOpensUpward } from "./dock";
// Song library control — a collapsible panel, bottom-right, mirroring the
// LyricsControl/StyleControl pattern. Talks entirely through the socket's
// song-library methods (PROTOCOL.md "Song library" section):
//   - list/load known songs, with checkboxes to build and load a setlist
//   - import lyrics from a letras.mus.br/cifraclub.com.br URL
//   - save the currently loaded lyrics as a new song
// Hidden under ?clean=1 like the other operator controls. There is no local
// state beyond the last-fetched list — the backend is the source of truth,
// re-fetched on open and after every load/save/import.

import type { SongSummary, SongLoadedMsg } from "./socket";

type ListSongsCb = () => void;
type LoadSongCb = (id: string) => void;
type ImportSongCb = (url: string) => void;
type SaveSongCb = (title: string, artist: string) => void;
type LoadSetlistCb = (ids: string[]) => void;

export class SongLibraryControl {
  private panel: HTMLDivElement;
  private select: HTMLSelectElement;
  private setlistEl: HTMLDivElement;
  private status: HTMLSpanElement;
  private importInput: HTMLInputElement;
  private saveTitleInput: HTMLInputElement;
  private saveArtistInput: HTMLInputElement;
  private open = false;
  private songs: SongSummary[] = [];
  private checked = new Set<string>();
  private currentSongId: string | null = null;

  constructor(
    private onListSongs: ListSongsCb,
    private onLoadSong: LoadSongCb,
    private onImportSong: ImportSongCb,
    private onSaveSong: SaveSongCb,
    private onLoadSetlist: LoadSetlistCb,
  ) {
    const wrap = document.createElement("div");
    const toggle = document.createElement("button");
    toggle.type = "button";
    toggle.textContent = "songs";
    toggle.title = "Known songs — load, import from a URL, build a setlist";
    Object.assign(toggle.style, {
      background: "rgba(0,0,0,0.55)",
      border: "1px solid #374151",
      borderRadius: "3px",
      color: "#9ca3af",
      font: "inherit",
      letterSpacing: "0.1em",
      padding: "4px 8px",
      cursor: "pointer",
      opacity: "0.7",
    } as CSSStyleDeclaration);
    toggle.addEventListener("click", () => this.toggleOpen());

    this.panel = document.createElement("div");
    Object.assign(this.panel.style, {
      display: "none",
      flexDirection: "column",
      gap: "8px",
      padding: "8px",
      width: "320px",
      maxHeight: "60vh",
      overflowY: "auto",
      background: "rgba(0,0,0,0.75)",
      border: "1px solid #374151",
      borderRadius: "4px",
    } as CSSStyleDeclaration);
    panelOpensUpward(this.panel);

    // A <select> rather than a row per song: the panel used to grow by one
    // line for every song in the library, which is fine at three and unusable
    // at thirty. The combo stays one line tall no matter how big the catalog
    // gets, and the browser gives keyboard search over it for free.
    const pickRow = row();
    this.select = document.createElement("select");
    Object.assign(this.select.style, {
      flex: "1 1 auto",
      minWidth: "0",
      background: "rgba(0,0,0,0.55)",
      border: "1px solid #374151",
      borderRadius: "2px",
      color: "#e5e7eb",
      font: "inherit",
      padding: "3px 6px",
      cursor: "pointer",
    } as CSSStyleDeclaration);

    const loadBtn = this.button("Load", () => {
      const id = this.select.value;
      if (id) this.onLoadSong(id);
    });
    const queueBtn = this.button("+ Setlist", () => {
      const id = this.select.value;
      if (id) {
        this.checked.add(id);
        this.renderSetlist();
      }
    });
    pickRow.append(this.select, loadBtn, queueBtn);

    // The queued setlist, as a compact line of chips with the running order —
    // replaces the per-song checkbox, which gave no sense of ORDER and needed
    // a scan of the whole list to read back what was selected.
    this.setlistEl = document.createElement("div");
    Object.assign(this.setlistEl.style, {
      display: "flex",
      flexWrap: "wrap",
      alignItems: "center",
      gap: "4px",
    } as CSSStyleDeclaration);

    const setlistRow = row();
    setlistRow.style.flexDirection = "column";
    setlistRow.style.alignItems = "stretch";
    setlistRow.appendChild(this.setlistEl);

    const importRow = row();
    this.importInput = document.createElement("input");
    this.importInput.type = "text";
    this.importInput.placeholder = "paste a letras.mus.br / cifraclub.com.br link…";
    Object.assign(this.importInput.style, inputStyle("1 1 auto"));
    const importBtn = this.button("Import", () => {
      const url = this.importInput.value.trim();
      if (url) {
        this.onImportSong(url);
        this.status.textContent = "importing…";
      }
    });
    importRow.appendChild(this.importInput);
    importRow.appendChild(importBtn);

    const saveRow = row();
    this.saveTitleInput = document.createElement("input");
    this.saveTitleInput.type = "text";
    this.saveTitleInput.placeholder = "title";
    Object.assign(this.saveTitleInput.style, inputStyle("1 1 auto"));
    this.saveArtistInput = document.createElement("input");
    this.saveArtistInput.type = "text";
    this.saveArtistInput.placeholder = "artist";
    Object.assign(this.saveArtistInput.style, inputStyle("1 1 auto"));
    const saveBtn = this.button("Save current", () => {
      const title = this.saveTitleInput.value.trim();
      if (title) {
        this.onSaveSong(title, this.saveArtistInput.value.trim());
        this.saveTitleInput.value = "";
        this.saveArtistInput.value = "";
      }
    });
    saveRow.appendChild(this.saveTitleInput);
    saveRow.appendChild(this.saveArtistInput);
    saveRow.appendChild(saveBtn);

    this.status = document.createElement("span");
    Object.assign(this.status.style, { color: "#9ca3af" } as CSSStyleDeclaration);

    this.panel.appendChild(pickRow);
    this.panel.appendChild(setlistRow);
    this.panel.appendChild(divider());
    this.panel.appendChild(importRow);
    this.panel.appendChild(saveRow);
    this.panel.appendChild(this.status);

    wrap.appendChild(toggle);
    wrap.appendChild(this.panel);
    mountInDock(wrap);
  }

  private toggleOpen() {
    this.open = !this.open;
    this.panel.style.display = this.open ? "flex" : "none";
    if (this.open) this.onListSongs();
  }

  private button(text: string, onClick: () => void): HTMLButtonElement {
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = text;
    Object.assign(b.style, {
      background: "transparent",
      border: "1px solid #374151",
      borderRadius: "2px",
      color: "#e5e7eb",
      font: "inherit",
      padding: "3px 8px",
      cursor: "pointer",
      whiteSpace: "nowrap",
    } as CSSStyleDeclaration);
    b.addEventListener("click", onClick);
    return b;
  }

  /** Refresh the list from a `songs` server push. */
  setSongs(songs: SongSummary[]) {
    this.songs = songs;
    this.renderList();
  }

  /** Reflect a `song_loaded`/`song_identified` push — highlights the active song. */
  setCurrentSong(m: SongLoadedMsg) {
    this.currentSongId = m.id;
    this.status.textContent = `loaded: ${m.title}${m.artist ? ` — ${m.artist}` : ""}`;
    this.renderList();
  }

  setSaved(m: SongLoadedMsg) {
    this.status.textContent = `saved: ${m.title}`;
    this.onListSongs();
  }

  setError(message: string) {
    this.status.textContent = `⚠ ${message}`;
  }

  private renderList() {
    const keep = this.select.value;
    this.select.innerHTML = "";

    if (this.songs.length === 0) {
      const opt = document.createElement("option");
      opt.value = "";
      opt.textContent = "no songs yet — import or save one below";
      this.select.appendChild(opt);
      this.select.disabled = true;
      this.renderSetlist();
      return;
    }

    this.select.disabled = false;
    for (const s of this.songs) {
      const opt = document.createElement("option");
      opt.value = s.id;
      // The loaded song is marked in the option text: a <select>'s own styling
      // is not reliably themable across browsers, so highlighting by colour
      // the way the old list did would silently do nothing on some of them.
      const label = s.artist ? `${s.title} — ${s.artist}` : s.title;
      opt.textContent = this.currentSongId === s.id ? `▸ ${label}` : label;
      this.select.appendChild(opt);
    }

    // Keep the operator's choice across a refresh; fall back to whatever is
    // loaded so the combo isn't showing something unrelated to the stage.
    if (keep && this.songs.some((s) => s.id === keep)) this.select.value = keep;
    else if (this.currentSongId) this.select.value = this.currentSongId;

    this.renderSetlist();
  }

  private renderSetlist() {
    this.setlistEl.innerHTML = "";
    if (this.checked.size === 0) return;

    const order = [...this.checked];
    order.forEach((id, i) => {
      const song = this.songs.find((s) => s.id === id);
      const chip = document.createElement("span");
      chip.textContent = `${i + 1}. ${song?.title ?? id} ✕`;
      chip.title = "Remove from the setlist";
      Object.assign(chip.style, {
        background: "rgba(147,197,253,0.15)",
        border: "1px solid #374151",
        borderRadius: "10px",
        padding: "1px 7px",
        cursor: "pointer",
        whiteSpace: "nowrap",
      } as CSSStyleDeclaration);
      chip.addEventListener("click", () => {
        this.checked.delete(id);
        this.renderSetlist();
      });
      this.setlistEl.appendChild(chip);
    });

    const go = this.button(`Load setlist (${order.length})`, () =>
      this.onLoadSetlist(order),
    );
    const clear = this.button("Clear", () => {
      this.checked.clear();
      this.renderSetlist();
    });
    this.setlistEl.append(go, clear);
  }
}

function row(): HTMLDivElement {
  const r = document.createElement("div");
  Object.assign(r.style, { display: "flex", gap: "6px" } as CSSStyleDeclaration);
  return r;
}

function divider(): HTMLDivElement {
  const d = document.createElement("div");
  Object.assign(d.style, { borderTop: "1px solid #374151", margin: "2px 0" } as CSSStyleDeclaration);
  return d;
}

function inputStyle(flex: string): CSSStyleDeclaration {
  return {
    flex,
    background: "transparent",
    border: "1px solid #374151",
    borderRadius: "2px",
    color: "#fff",
    font: "inherit",
    padding: "3px 6px",
    outline: "none",
    minWidth: "0",
  } as CSSStyleDeclaration;
}

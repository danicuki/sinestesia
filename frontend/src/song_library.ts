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
  private listEl: HTMLDivElement;
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
    Object.assign(wrap.style, {
      position: "fixed",
      bottom: "10px",
      right: "10px",
      zIndex: "20",
      display: "flex",
      flexDirection: "column",
      alignItems: "flex-end",
      gap: "6px",
      font: "11px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace",
      color: "#e5e7eb",
    } as CSSStyleDeclaration);

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

    this.listEl = document.createElement("div");
    Object.assign(this.listEl.style, { display: "flex", flexDirection: "column", gap: "2px" } as CSSStyleDeclaration);

    const setlistRow = row();
    const setlistBtn = this.button("Load Setlist (checked)", () => {
      if (this.checked.size > 0) this.onLoadSetlist([...this.checked]);
    });
    setlistRow.appendChild(setlistBtn);

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

    this.panel.appendChild(this.listEl);
    this.panel.appendChild(setlistRow);
    this.panel.appendChild(divider());
    this.panel.appendChild(importRow);
    this.panel.appendChild(saveRow);
    this.panel.appendChild(this.status);

    wrap.appendChild(toggle);
    wrap.appendChild(this.panel);
    document.body.appendChild(wrap);
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
    this.listEl.innerHTML = "";
    if (this.songs.length === 0) {
      const empty = document.createElement("div");
      empty.textContent = "no songs yet — import or save one below";
      Object.assign(empty.style, { color: "#6b7280" } as CSSStyleDeclaration);
      this.listEl.appendChild(empty);
      return;
    }

    for (const s of this.songs) {
      const line = row();
      Object.assign(line.style, { alignItems: "center", gap: "6px" } as CSSStyleDeclaration);

      const check = document.createElement("input");
      check.type = "checkbox";
      check.checked = this.checked.has(s.id);
      check.addEventListener("change", () => {
        if (check.checked) this.checked.add(s.id);
        else this.checked.delete(s.id);
      });

      const label = document.createElement("span");
      label.textContent = s.artist ? `${s.title} — ${s.artist}` : s.title;
      Object.assign(label.style, {
        flex: "1 1 auto",
        overflow: "hidden",
        textOverflow: "ellipsis",
        whiteSpace: "nowrap",
        color: this.currentSongId === s.id ? "#93c5fd" : "#e5e7eb",
        fontWeight: this.currentSongId === s.id ? "700" : "400",
      } as CSSStyleDeclaration);

      const loadBtn = this.button("Load", () => this.onLoadSong(s.id));

      line.appendChild(check);
      line.appendChild(label);
      line.appendChild(loadBtn);
      this.listEl.appendChild(line);
    }
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

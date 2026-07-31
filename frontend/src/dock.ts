// One shared bottom-right strip that every operator control mounts into.
//
// Each control used to position itself `fixed` at a corner it picked on its
// own, which does not compose: the song library and the take recorder both
// claimed bottom-right and landed exactly on top of each other, and the lyrics
// control sat on the verification badge in the bottom-left. Adding any new
// button meant finding a free corner, and there aren't any left.
//
// So the corner belongs to the dock, not to the controls. They append here and
// flow in one wrapping row; nothing overlaps, and order is just append order.
// The dock itself ignores pointer events so the stage canvas underneath stays
// clickable — each child turns them back on for itself.

let el: HTMLDivElement | null = null;

export function dock(): HTMLDivElement {
  if (el) return el;

  el = document.createElement("div");
  Object.assign(el.style, {
    position: "fixed",
    bottom: "10px",
    right: "10px",
    // Left edge too, so a long row wraps upward instead of running off screen.
    left: "10px",
    zIndex: "25",
    display: "flex",
    flexWrap: "wrap",
    justifyContent: "flex-end",
    alignItems: "flex-end",
    gap: "6px",
    pointerEvents: "none",
    font: "11px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace",
    color: "#e5e7eb",
  } as CSSStyleDeclaration);

  document.body.appendChild(el);
  return el;
}

// Mount a control into the dock. `relative` so the control's own pop-up panel
// can position itself against its button rather than the viewport.
export function mountInDock(node: HTMLElement): void {
  Object.assign(node.style, {
    position: "relative",
    pointerEvents: "auto",
    display: "flex",
    flexDirection: "column",
    alignItems: "flex-end",
    gap: "6px",
  } as CSSStyleDeclaration);

  dock().appendChild(node);
}

// Panels in the dock open UPWARD — there is nothing below them but the edge of
// the screen.
export function panelOpensUpward(panel: HTMLElement): void {
  Object.assign(panel.style, {
    position: "absolute",
    bottom: "calc(100% + 6px)",
    right: "0",
    // Clear whatever the control set before it lived in the dock — the style
    // control, for one, used to open downward from a top-right anchor.
    top: "auto",
    left: "auto",
  } as CSSStyleDeclaration);
}

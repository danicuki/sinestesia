# Sinestesia landing page

A single self-contained `index.html` — fonts inlined, no build step, no external
requests except the YouTube link-outs. Deploy it anywhere that serves static files:

- **GitHub Pages**: Settings → Pages → deploy from branch, folder `/site`.
- **Netlify / Vercel / Cloudflare Pages**: drag-and-drop the `site/` folder.

Things to update before going live:

- **Booking email** — currently `danicuki@gmail.com` in the `#book` section
  (consider `book@sinestesia.art` on a custom domain for credibility).
- **OG image** — add a `<meta property="og:image">` pointing to a hosted still
  from the NFC Summit video so link previews show the stage.
- **Portuguese version** — duplicate as `index.pt.html` and translate; agencies
  in Portugal convert better in PT.
- The hero canvas animation is hand-coded (Canvas 2D, ~150 lines at the bottom
  of the file). Element coordinates are relative (0–1), so the scene scales with
  the panel.

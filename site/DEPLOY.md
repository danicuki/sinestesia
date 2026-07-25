# Deploying the landing site

Static HTML on Vercel. No build step, no environment variables — the whole point
is that it stays trivially deployable and can't break during a show.

```bash
cd site
vercel link          # new project, e.g. sinestesia-www; framework: Other
vercel --prod
```

`vercel.json` sets `cleanUrls`, so `/artists.html` is reachable as `/artists`.
Link between pages **without** the `.html` extension so URLs don't change if the
files are reorganised.

## Custom domain

```bash
vercel domains add sinestesia.xyz          # once you own it
vercel alias set <deployment-url> www.sinestesia.xyz
```

Or add the domain in the Vercel dashboard, which also provisions the
certificate. `app.sinestesia.xyz` should point at the **frontend** project, not
this one; keep the marketing site and the running app as separate deployments so
a change to one can never take down the other.

## Rules for this site

- **Self-contained.** No CDN scripts, no external fonts, no remote images —
  everything inlined or in `assets/`. Venue wifi is unreliable and the site is
  shown to people in rooms with bad connectivity.
- **No secrets.** This is a public marketing page; nothing here should ever read
  an API key.
- **Honest claims only.** No invented venues, artists, testimonials or metrics.
  If a section needs proof that doesn't exist yet, leave the slot visibly empty
  rather than filling it with fiction.

/**
 * Render a Claude Design (.dc.html) prototype into a plain, self-contained page.
 *
 *   node tools/render-design.mjs <bundle-project-dir> <out-dir>
 *
 * The exported prototypes are not static HTML: they are components driven by a
 * design-tool runtime (support.js, which needs React) using three constructs —
 * `<sc-for list="{{ xs }}" as="x">`, `<sc-if value="{{ flag }}">` and `{{ expr }}`
 * interpolation — fed by a `renderVals()` method. Shipping them as-is would
 * publish literal `{{ line }}` placeholders and a script that throws.
 *
 * So we evaluate the component once with its default props, expand the
 * templates, lift `componentDidMount()` into an ordinary DOMContentLoaded
 * script (that's where the reveal/video behaviour lives), and drop the runtime.
 *
 * Re-run it whenever the designer exports a new bundle; don't hand-edit output.
 */
import { readFileSync, writeFileSync, mkdirSync, copyFileSync, readdirSync, existsSync } from 'node:fs';
import { join, basename } from 'node:path';

const [, , SRC, OUT] = process.argv;
if (!SRC || !OUT) {
  console.error('usage: node tools/render-design.mjs <bundle-project-dir> <out-dir>');
  process.exit(1);
}

/** Pages are linked by slug; .dc.html names become clean URLs. */
const SLUGS = {
  'Sinestesia-Artists': 'index',
  'Sinestesia-Producers': 'producers',
  'Sinestesia-Under-The-Hood': 'under-the-hood',
  'Sinestesia-Wordmark': 'identity',
};

const esc = (v) =>
  String(v ?? '').replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' })[c]);

/** Resolve a dotted path ("faq.q") against the scope chain. */
function lookup(expr, scope) {
  const trimmed = expr.trim();
  if (trimmed === 'true') return true;
  if (trimmed === 'false') return false;
  return trimmed.split('.').reduce((acc, k) => (acc == null ? undefined : acc[k]), scope);
}

/** Replace {{ expr }} using the current scope. */
function interpolate(html, scope) {
  return html.replace(/\{\{([^}]*)\}\}/g, (_, e) => esc(lookup(e, scope)));
}

/**
 * Expand sc-for / sc-if. Written as an explicit scan rather than a regex so
 * nested blocks (an sc-if inside an sc-for) resolve correctly.
 */
function expand(html, scope) {
  const open = /<sc-(for|if)\b([^>]*)>/;
  const m = open.exec(html);
  if (!m) return interpolate(html, scope);

  const [full, kind, attrs] = m;
  const start = m.index;

  // Find this tag's matching close, accounting for nesting of the same kind.
  const openRe = new RegExp(`<sc-${kind}\\b[^>]*>`, 'g');
  const closeTag = `</sc-${kind}>`;
  let depth = 0;
  let i = start;
  let end = -1;
  while (i < html.length) {
    openRe.lastIndex = i;
    const nextOpen = openRe.exec(html);
    const nextClose = html.indexOf(closeTag, i);
    if (nextClose === -1) throw new Error(`unclosed <sc-${kind}>`);
    if (nextOpen && nextOpen.index < nextClose) {
      depth++;
      i = nextOpen.index + nextOpen[0].length;
    } else {
      depth--;
      if (depth === 0) {
        end = nextClose;
        break;
      }
      i = nextClose + closeTag.length;
    }
  }
  if (end === -1) throw new Error(`unclosed <sc-${kind}>`);

  const inner = html.slice(start + full.length, end);
  const after = html.slice(end + closeTag.length);
  const before = interpolate(html.slice(0, start), scope);

  let rendered = '';
  if (kind === 'for') {
    const list = lookup(/list="\{\{([^}]*)\}\}"/.exec(attrs)?.[1] ?? '', scope);
    const as = /as="([^"]*)"/.exec(attrs)?.[1] ?? 'item';
    for (const item of Array.isArray(list) ? list : []) {
      rendered += expand(inner, { ...scope, [as]: item });
    }
  } else {
    if (lookup(/value="\{\{([^}]*)\}\}"/.exec(attrs)?.[1] ?? '', scope)) {
      rendered = expand(inner, scope);
    }
  }

  return before + rendered + expand(after, scope);
}

/** Run the prototype's component logic to get its data + mount effects. */
async function evaluateComponent(scriptBody, props) {
  const shim = `
    class DCLogic {
      constructor(p) { this.props = p; }
      setState() {}
    }
    ${scriptBody}
    globalThis.__C = Component;
  `;
  const mod = await import(`data:text/javascript,${encodeURIComponent(shim)}`);
  void mod;
  const C = globalThis.__C;
  const instance = new C(props);
  return instance.renderVals ? instance.renderVals() : {};
}

/** Extract componentDidMount's body so it can run as an ordinary script. */
function mountBody(scriptBody) {
  const i = scriptBody.indexOf('componentDidMount()');
  if (i === -1) return null;
  const braceStart = scriptBody.indexOf('{', i);
  let depth = 0;
  for (let j = braceStart; j < scriptBody.length; j++) {
    if (scriptBody[j] === '{') depth++;
    else if (scriptBody[j] === '}') {
      depth--;
      if (depth === 0) return scriptBody.slice(braceStart + 1, j);
    }
  }
  return null;
}

async function renderPage(file) {
  const raw = readFileSync(file, 'utf8');
  const name = basename(file).replace('.dc.html', '');

  const scriptRe = /<script type="text\/x-dc"[^>]*data-props="([^"]*)"[^>]*>([\s\S]*?)<\/script>/;
  const sm = scriptRe.exec(raw);

  let html = raw;
  let vals = {};
  let mount = null;

  // A page can carry an x-dc block with no component (the identity sheet is
  // static markup); only evaluate when there is actually a class to run.
  if (sm) {
    if (/class\s+Component\b/.test(sm[2])) {
      const propsSpec = JSON.parse(sm[1].replace(/&quot;/g, '"'));
      const props = Object.fromEntries(
        Object.entries(propsSpec).map(([k, v]) => [k, v.default]),
      );
      vals = await evaluateComponent(sm[2], props);
      mount = mountBody(sm[2]);
    }
    html = html.replace(scriptRe, '');
  }

  // Drop the design-tool runtime — it needs React and does nothing we keep.
  html = html.replace(/<script src="\.\/support\.js"><\/script>\s*/g, '');

  html = expand(html, vals);

  // Re-attach the prototype's own behaviour as a plain script.
  if (mount) {
    const script = `<script>
document.addEventListener('DOMContentLoaded', function () {
${mount}
});
</script>`;
    html = html.replace(/<\/body>/i, `${script}\n</body>`);
  }

  // Rewrite cross-page links to clean URLs (vercel.json sets cleanUrls).
  for (const [from, to] of Object.entries(SLUGS)) {
    const target = to === 'index' ? '/' : `/${to}`;
    html = html.replaceAll(`${from}.dc.html`, target);
  }

  const outName = `${SLUGS[name] ?? name.toLowerCase()}.html`;
  writeFileSync(join(OUT, outName), html);

  const left = (html.match(/\{\{|<sc-(for|if)/g) || []).length;
  console.log(
    `  ${outName.padEnd(20)} ${(html.length / 1024).toFixed(0).padStart(4)}KB` +
      (left ? `  ⚠ ${left} unrendered construct(s)` : '  ✓ fully rendered'),
  );
  return left;
}

mkdirSync(OUT, { recursive: true });
const files = readdirSync(SRC).filter((f) => f.endsWith('.dc.html'));
let problems = 0;
for (const f of files) problems += await renderPage(join(SRC, f));

// Copy only the assets the pages actually reference.
const assetsDir = join(SRC, 'assets');
if (existsSync(assetsDir)) {
  const pages = readdirSync(OUT).filter((f) => f.endsWith('.html'));
  const used = new Set();
  for (const p of pages) {
    const s = readFileSync(join(OUT, p), 'utf8');
    for (const m of s.matchAll(/assets\/([A-Za-z0-9._-]+)/g)) used.add(m[1]);
  }
  mkdirSync(join(OUT, 'assets'), { recursive: true });
  for (const a of used) {
    const src = join(assetsDir, a);
    if (existsSync(src)) copyFileSync(src, join(OUT, 'assets', a));
    else console.log(`  ⚠ referenced but missing: assets/${a}`);
  }
  console.log(`  assets: ${[...used].join(', ')}`);
}

process.exit(problems ? 1 : 0);

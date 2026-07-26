#!/usr/bin/env bash
# render-doc-html.sh — wrap a meeting document (summary or changes/decision
# doc) in a self-contained, print-optimized HTML file. Zero required deps:
# the user opens the result and hits Ctrl/Cmd-P → "Save as PDF". No pandoc,
# weasyprint, wkhtmltopdf, or headless browser is assumed to exist — that is
# the plugin-portability constraint (works in any installed environment).
#
# The document BODY comes from one of two sources:
#   --md <file>        Convert markdown → HTML body with pandoc IF pandoc is
#                      installed (best fidelity). If pandoc is absent, exit 3
#                      so the caller falls back to --body-file.
#   --body-file <file> Use a pre-rendered HTML fragment as the body. The
#                      /meeting skill already holds the structured content,
#                      so it can author this fragment directly with no
#                      markdown parser in the loop.
#
# Usage:
#   render-doc-html.sh --title "…" --out out.html --md doc.md
#   render-doc-html.sh --title "…" --out out.html --body-file body.html
#
# Exit codes: 0 ok · 2 usage error · 3 pandoc requested but unavailable.
set -euo pipefail

TITLE="" OUT="" MD="" BODY_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --title)     TITLE="$2"; shift 2 ;;
    --out)       OUT="$2"; shift 2 ;;
    --md)        MD="$2"; shift 2 ;;
    --body-file) BODY_FILE="$2"; shift 2 ;;
    *) echo "render-doc-html: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$OUT" ] || { echo "render-doc-html: --out is required" >&2; exit 2; }
[ -n "$TITLE" ] || TITLE="Meeting Document"
# Escape HTML-special chars so a title with < > & can't inject markup into <title>.
# Use sed for portability: bash 5.2+ treats an unescaped & in ${//} replacements
# as the matched text, which differs from older bash — sed's behavior is stable.
TITLE=$(printf '%s' "$TITLE" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

# --- Resolve the HTML body ------------------------------------------------
BODY=""
if [ -n "$MD" ]; then
  [ -f "$MD" ] || { echo "render-doc-html: --md file not found: $MD" >&2; exit 2; }
  if command -v pandoc >/dev/null 2>&1; then
    BODY="$(pandoc --from=gfm --to=html "$MD")"
  else
    echo "render-doc-html: pandoc not installed — re-invoke with --body-file (caller-authored HTML body)" >&2
    exit 3
  fi
elif [ -n "$BODY_FILE" ]; then
  [ -f "$BODY_FILE" ] || { echo "render-doc-html: --body-file not found: $BODY_FILE" >&2; exit 2; }
  BODY="$(cat "$BODY_FILE")"
else
  echo "render-doc-html: provide either --md or --body-file" >&2; exit 2
fi

# --- Emit the self-contained document -------------------------------------
# Print CSS: A4/Letter page box, readable measure, page-break-avoidance on
# headings and tables, and a screen/print-neutral palette. Everything is
# inlined; no external host is contacted (works offline and under strict CSP).
cat > "$OUT" <<HTMLHEAD
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${TITLE}</title>
<style>
  :root { --ink:#1a1a1a; --muted:#5b6472; --rule:#d9dee6; --accent:#2d5bd7; --bg:#ffffff; }
  @media (prefers-color-scheme: dark) {
    :root { --ink:#e6e9ef; --muted:#9aa4b2; --rule:#333a45; --accent:#7aa2ff; --bg:#14171c; }
  }
  * { box-sizing: border-box; }
  html, body { background: var(--bg); color: var(--ink); }
  body {
    font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    max-width: 46rem; margin: 2.5rem auto; padding: 0 1.25rem;
  }
  h1 { font-size: 1.9rem; line-height: 1.2; margin: 0 0 1rem; }
  h2 { font-size: 1.25rem; margin: 2rem 0 .5rem; padding-top: .4rem; border-top: 1px solid var(--rule); }
  h3 { font-size: 1.05rem; margin: 1.3rem 0 .4rem; }
  h2, h3, h4 { break-after: avoid; }
  p, li { orphans: 2; widows: 2; }
  a { color: var(--accent); text-decoration: none; }
  code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: .88em; }
  pre { background: rgba(127,127,127,.10); padding: .8rem 1rem; border-radius: 6px; overflow-x: auto; }
  table { border-collapse: collapse; width: 100%; margin: .6rem 0; break-inside: avoid; }
  th, td { border: 1px solid var(--rule); padding: .4rem .6rem; text-align: left; vertical-align: top; }
  th { background: rgba(127,127,127,.08); }
  blockquote { margin: .6rem 0; padding: .2rem 0 .2rem 1rem; border-left: 3px solid var(--rule); color: var(--muted); }
  ul, ol { padding-left: 1.3rem; }
  @page { size: A4; margin: 18mm 16mm; }
  @media print {
    body { max-width: none; margin: 0; }
    :root { --bg:#ffffff; --ink:#111111; }
    h2 { break-before: auto; }
  }
</style>
</head>
<body>
HTMLHEAD

printf '%s\n' "$BODY" >> "$OUT"

cat >> "$OUT" <<'HTMLFOOT'
</body>
</html>
HTMLFOOT

echo "$OUT"

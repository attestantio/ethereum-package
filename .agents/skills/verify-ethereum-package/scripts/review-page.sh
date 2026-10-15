#!/usr/bin/env bash
# Build <evidence-dir>/index.html from SETUP-before.md, SETUP-after.md and REPORT.md, then open it.
# Usage: review-page.sh <evidence-dir> [--no-open]
# Sign-off status comes from <evidence-dir>/signoff.md. Needs uv (or python3 with `markdown`).
set -euo pipefail
if [[ $# -lt 1 ]]; then
  echo "usage: $0 <evidence-dir> [--no-open]" >&2
  exit 64
fi
dir="$(cd "$1" && pwd)"

uv run -q --with markdown python - "$dir" <<'EOF'
import html, pathlib, sys
from datetime import datetime, timezone
import markdown

d = pathlib.Path(sys.argv[1])
signoff = d / "signoff.md"

def section(title, path):
    body = (markdown.markdown(path.read_text(), extensions=["tables", "fenced_code"])
            if path.exists() else "<p class=muted>Not written yet.</p>")
    return f'<section><h2>{title}</h2><p class="muted src">{html.escape(str(path))}</p>{body}</section>'

if signoff.exists():
    status = f'<div class="banner ok">Setup signed off. {html.escape(signoff.read_text().strip())}</div>'
else:
    status = ('<div class="banner pending">Sign-off pending. The live validation is not successful until '
              'the setup below is confirmed.</div>')

page = f"""<!doctype html><html lang=en><head><meta charset=utf-8>
<title>{html.escape(d.name)}: validation review</title><style>
:root {{ color-scheme: light dark; --bg:#fff; --ink:#1a1a1a; --muted:#5b6470; --line:#d8dee4;
  --code:#f3f5f7; --ok:#1a7f37; --warn:#9a6700; --okbg:#dafbe1; --warnbg:#fff8c5; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#0f1419; --ink:#e6edf3; --muted:#9aa7b4;
  --line:#30363d; --code:#161b22; --ok:#3fb950; --warn:#d29922; --okbg:#12261a; --warnbg:#2b2111; }} }}
body {{ background:var(--bg); color:var(--ink); font:15px/1.55 -apple-system,system-ui,sans-serif;
  max-width:1100px; margin:2rem auto; padding:0 1.5rem; }}
nav a {{ margin-right:1rem; color:var(--ink); }}
section {{ border-top:1px solid var(--line); margin-top:2rem; padding-top:.5rem; }}
table {{ border-collapse:collapse; width:100%; font-size:13px; display:block; overflow-x:auto; }}
th,td {{ border:1px solid var(--line); padding:4px 8px; text-align:left; vertical-align:top; }}
code, pre {{ background:var(--code); border-radius:4px; font-size:12.5px; }}
code {{ padding:1px 4px; word-break:break-all; }} pre {{ padding:8px; overflow-x:auto; }}
.muted {{ color:var(--muted); }} .src {{ font-size:12px; margin-top:-.5rem; }}
.banner {{ padding:.75rem 1rem; border-radius:6px; font-weight:600; }}
.ok {{ background:var(--okbg); color:var(--ok); }} .pending {{ background:var(--warnbg); color:var(--warn); }}
</style></head><body>
<h1>{html.escape(d.name)}</h1>
<p class=muted>Generated {datetime.now(timezone.utc):%Y-%m-%d %H:%M} UTC from {html.escape(str(d))}</p>
{status}
<nav><a href="#before">Setup before</a><a href="#after">Setup after</a><a href="#report">Report</a></nav>
<div id=before>{section("Setup before", d / "SETUP-before.md")}</div>
<div id=after>{section("Setup after", d / "SETUP-after.md")}</div>
<div id=report>{section("Report", d / "REPORT.md")}</div>
</body></html>"""
(d / "index.html").write_text(page)
print(d / "index.html")
EOF

[[ "${2:-}" == --no-open ]] || { command -v open >/dev/null && open "$dir/index.html" || xdg-open "$dir/index.html"; }

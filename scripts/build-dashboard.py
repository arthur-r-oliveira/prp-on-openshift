#!/usr/bin/env python3
"""Builds the test-health dashboard from GitHub Actions JUnit artifacts.

Both test workflows already upload JUnit XML (scripts/to-junit-xml.sh), so the
run history is a usable time series without storing anything extra - this
script just collects it. Artifacts are the only source; nothing is read from
the lab, so the dashboard never carries a site-specific hostname.

Output is one self-contained HTML file: no network fetches, no build step, no
framework. It opens from a file:// URL as readily as from Pages.

Usage: ./scripts/build-dashboard.py [--out site/index.html] [--limit 100]
"""

import argparse
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from collections import defaultdict
from datetime import datetime, timezone

# Workflow name -> short label. Anything not listed still charts, under its
# own name; this only controls the compact labels used in the legend.
WORKFLOW_LABELS = {
    "PRP failover test": "PRP failover",
    "PRP UDP benchmark": "PRP benchmark",
    "SNO test matrix (wipe + single + dual-sidecar-prp)": "SNO matrix",
}


def gh(*args, check=True):
    r = subprocess.run(["gh", *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.exit(f"gh {' '.join(args)} failed:\n{r.stderr.strip()}")
    return r.stdout


def collect(limit):
    """Returns (runs, records). A run with no parsable artifact is skipped."""
    raw = gh(
        "run", "list", "--limit", str(limit), "--json",
        "databaseId,createdAt,conclusion,workflowName,headSha,url",
    )
    runs_meta = {str(r["databaseId"]): r for r in json.loads(raw)}

    runs, records = [], []
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="dashboard-"))
    try:
        for rid, meta in runs_meta.items():
            dest = tmp / rid
            dest.mkdir(parents=True, exist_ok=True)
            # A cancelled or still-running job has no artifact; that is normal.
            if subprocess.run(
                ["gh", "run", "download", rid, "-D", str(dest)],
                capture_output=True, text=True,
            ).returncode != 0:
                continue

            found = False
            for xml in dest.rglob("*.xml"):
                try:
                    root = ET.parse(xml).getroot()
                except ET.ParseError:
                    continue
                for suite in root.findall(".//testsuite") or [root]:
                    for case in suite.findall(".//testcase"):
                        bad = (case.find("failure") is not None
                               or case.find("error") is not None)
                        records.append({
                            "run": rid,
                            "test": case.get("name"),
                            "ok": not bad,
                        })
                        found = True
            if found:
                wf = meta["workflowName"]
                runs.append({
                    "id": rid,
                    "date": meta["createdAt"][:10],
                    "at": meta["createdAt"],
                    "wf": wf,
                    "label": WORKFLOW_LABELS.get(wf, wf),
                    "sha": meta["headSha"][:7],
                    "url": meta["url"],
                })
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    runs.sort(key=lambda r: r["at"])
    return runs, records


def aggregate(runs, records):
    order = {r["id"]: i for i, r in enumerate(runs)}
    records = [r for r in records if r["run"] in order]

    by_test = defaultdict(lambda: {"pass": 0, "total": 0})
    for r in records:
        t = by_test[r["test"]]
        t["total"] += 1
        t["pass"] += r["ok"]
    tests = [
        {"test": k, "pass": v["pass"], "total": v["total"],
         "rate": round(100 * v["pass"] / v["total"], 1)}
        for k, v in by_test.items()
    ]
    # Worst first: a health dashboard leads with what needs attention. Ties
    # break on sample count, so a 0/1 blip ranks below a sustained failure.
    tests.sort(key=lambda t: (t["rate"], -t["total"]))

    by_run = defaultdict(lambda: {"pass": 0, "total": 0})
    for r in records:
        b = by_run[r["run"]]
        b["total"] += 1
        b["pass"] += r["ok"]
    for run in runs:
        b = by_run[run["id"]]
        run["pass"], run["total"] = b["pass"], b["total"]
        run["rate"] = round(100 * b["pass"] / b["total"], 1) if b["total"] else 0

    cells = {f"{r['run']}|{r['test']}": r["ok"] for r in records}

    total = len(records)
    passed = sum(r["ok"] for r in records)

    # Consecutive fully-green runs, counting back from the most recent.
    streak = 0
    for run in reversed(runs):
        if run["pass"] == run["total"] and run["total"]:
            streak += 1
        else:
            break

    return {
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "runs": runs,
        "tests": tests,
        "cells": cells,
        "totals": {
            "records": total,
            "passed": passed,
            "rate": round(100 * passed / total, 1) if total else 0,
            "runs": len(runs),
            "types": len(tests),
            "streak": streak,
            "first": runs[0]["date"] if runs else "-",
            "last": runs[-1]["date"] if runs else "-",
        },
    }


# Palette values come from the data-viz reference palette. The two categorical
# slots (blue, orange) were validated in both modes - all checks pass. The
# status pair (good/critical) cannot clear CVD separation, because red/green IS
# the semantics; every status mark therefore carries a glyph and a label, so
# hue is never the only channel.
HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PRP / SNO test health</title>
<style>
  .viz-root {
    color-scheme: light;
    --surface-1: #fcfcfb;
    --plane: #f9f9f7;
    --text-primary: #0b0b0b;
    --text-secondary: #52514e;
    --muted: #898781;
    --grid: #e1e0d9;
    --axis: #c3c2b7;
    --border: rgba(11,11,11,0.10);
    --series-1: #2a78d6;
    --series-2: #eb6834;
    --series-3: #1baf7a;
    --series-4: #eda100;
    --good: #0ca30c;
    --critical: #d03b3b;
    --good-wash: rgba(12,163,12,0.14);
    --critical-wash: rgba(208,59,59,0.14);
  }
  @media (prefers-color-scheme: dark) {
    :root:where(:not([data-theme="light"])) .viz-root {
      color-scheme: dark;
      --surface-1: #1a1a19; --plane: #0d0d0d;
      --text-primary: #ffffff; --text-secondary: #c3c2b7; --muted: #898781;
      --grid: #2c2c2a; --axis: #383835; --border: rgba(255,255,255,0.10);
      --series-1: #3987e5; --series-2: #d95926;
      --series-3: #199e70; --series-4: #c98500;
      --good-wash: rgba(12,163,12,0.22); --critical-wash: rgba(208,59,59,0.22);
    }
  }
  :root[data-theme="dark"] .viz-root {
    color-scheme: dark;
    --surface-1: #1a1a19; --plane: #0d0d0d;
    --text-primary: #ffffff; --text-secondary: #c3c2b7; --muted: #898781;
    --grid: #2c2c2a; --axis: #383835; --border: rgba(255,255,255,0.10);
    --series-1: #3987e5; --series-2: #d95926;
      --series-3: #199e70; --series-4: #c98500;
    --good-wash: rgba(12,163,12,0.22); --critical-wash: rgba(208,59,59,0.22);
  }

  * { box-sizing: border-box; }
  body { margin: 0; }
  .viz-root {
    background: var(--plane);
    color: var(--text-primary);
    font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
    min-height: 100vh;
    padding: 32px 24px 56px;
  }
  .wrap { max-width: 1080px; margin: 0 auto; }

  header.top { display: flex; align-items: flex-start; gap: 16px; flex-wrap: wrap; margin-bottom: 28px; }
  header.top h1 { font-size: 22px; font-weight: 600; margin: 0 0 4px; letter-spacing: -0.01em; }
  .sub { color: var(--text-secondary); font-size: 13px; margin: 0; }
  .spacer { flex: 1 1 auto; }
  .controls { display: flex; gap: 8px; }
  button.ctl {
    font: inherit; font-size: 12px; color: var(--text-secondary);
    background: var(--surface-1); border: 1px solid var(--border);
    border-radius: 7px; padding: 7px 12px; cursor: pointer;
  }
  button.ctl:hover { color: var(--text-primary); }
  button.ctl[aria-pressed="true"] { color: var(--text-primary); border-color: var(--axis); }

  .kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 14px; margin-bottom: 26px; }
  .tile { background: var(--surface-1); border: 1px solid var(--border); border-radius: 12px; padding: 16px 18px; }
  .tile .k { font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); margin-bottom: 8px; }
  .tile .v { font-size: 30px; font-weight: 600; line-height: 1; letter-spacing: -0.02em; }
  .tile.hero .v { font-size: 48px; }
  .tile .note { font-size: 12px; color: var(--text-secondary); margin-top: 7px; }

  .card { background: var(--surface-1); border: 1px solid var(--border); border-radius: 12px; padding: 20px 22px 16px; margin-bottom: 18px; }
  .card h2 { font-size: 14px; font-weight: 600; margin: 0 0 3px; }
  .card .cap { font-size: 12px; color: var(--text-secondary); margin: 0 0 16px; }

  .legend { display: flex; gap: 16px; flex-wrap: wrap; font-size: 12px; color: var(--text-secondary); margin-bottom: 12px; }
  .legend span { display: inline-flex; align-items: center; gap: 6px; }
  .swatch { width: 10px; height: 10px; border-radius: 3px; display: inline-block; }

  /* viewBox drives the aspect ratio; no fixed height, so a chart fills its
     card instead of letterboxing inside it. */
  svg { display: block; width: 100%; height: auto; overflow: visible; }
  /* The matrix grows a column per run. Below its natural width it scrolls
     rather than shrinking the glyphs into illegibility. */
  .scroll-x { overflow-x: auto; overflow-y: hidden; }
  .tick { font-size: 11px; fill: var(--muted); font-variant-numeric: tabular-nums; }
  .cat { font-size: 12px; fill: var(--text-secondary); }
  .val { font-size: 11px; fill: var(--text-secondary); font-variant-numeric: tabular-nums; }
  .gridline { stroke: var(--grid); stroke-width: 1; }
  .axisline { stroke: var(--axis); stroke-width: 1; }

  table { border-collapse: collapse; width: 100%; font-size: 12px; }
  th, td { text-align: left; padding: 7px 10px; border-bottom: 1px solid var(--grid); }
  th { color: var(--muted); font-weight: 600; font-size: 11px; text-transform: uppercase; letter-spacing: 0.05em; }
  td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
  .tsub { font-size: 12px; font-weight: 600; color: var(--text-secondary); margin: 18px 0 6px; }
  .tsub:first-of-type { margin-top: 0; }
  .hidden { display: none; }

  #tip {
    position: fixed; pointer-events: none; opacity: 0; transition: opacity .09s;
    background: var(--surface-1); color: var(--text-primary);
    border: 1px solid var(--axis); border-radius: 8px; padding: 8px 11px;
    font-size: 12px; line-height: 1.5; box-shadow: 0 6px 20px rgba(0,0,0,.14);
    z-index: 50; max-width: 290px;
  }
  #tip b { font-weight: 600; }
  #tip .mono { font-variant-numeric: tabular-nums; }

  footer { color: var(--muted); font-size: 12px; margin-top: 26px; line-height: 1.6; }
  a { color: inherit; }

  /* Forced colors: hue disappears, so lean on the glyph + border that every
     status mark already carries. */
  @media (forced-colors: active) {
    .cell rect { forced-color-adjust: none; fill: Canvas; stroke: CanvasText; }
    .cell text { fill: CanvasText; }
  }
</style>
</head>
<body data-palette="#2a78d6,#eb6834">
<div class="viz-root">
<div class="wrap">

  <header class="top">
    <div>
      <h1>PRP / SNO test health</h1>
      <p class="sub" id="subtitle"></p>
    </div>
    <div class="spacer"></div>
    <div class="controls">
      <button class="ctl" id="tableBtn" aria-pressed="false">Table view</button>
      <button class="ctl" id="themeBtn">Theme</button>
    </div>
  </header>

  <section class="kpis" id="kpis"></section>

  <section class="card">
    <h2>Pass rate by test type</h2>
    <p class="cap">Share of runs in which each test passed. Worst first.</p>
    <div id="bars"></div>
  </section>

  <section class="card">
    <h2>Pass rate over time</h2>
    <p class="cap">One point per CI run, by suite.</p>
    <div class="legend" id="lineLegend"></div>
    <div id="line"></div>
  </section>

  <section class="card">
    <h2>Every test, every run</h2>
    <p class="cap">Columns are runs oldest to newest. Blank means the test did not run in that suite.</p>
    <div class="legend">
      <span><i class="swatch" style="background:var(--good)"></i> &#10003; pass</span>
      <span><i class="swatch" style="background:var(--critical)"></i> &#10007; fail</span>
      <span><i class="swatch" style="background:var(--grid)"></i> not run</span>
    </div>
    <div id="matrix" class="scroll-x"></div>
  </section>

  <section class="card hidden" id="tableCard">
    <h2>Table view</h2>
    <p class="cap">The same data, WCAG-clean - no reliance on color.</p>
    <h3 class="tsub">By test type</h3>
    <table id="tblTests"></table>
    <h3 class="tsub">By run</h3>
    <table id="tblRuns"></table>
  </section>

  <footer id="foot"></footer>
</div>
</div>
<div id="tip" role="status" aria-live="polite"></div>

<script id="data" type="application/json">__DATA__</script>
<script>
const D = JSON.parse(document.getElementById('data').textContent);
const tip = document.getElementById('tip');
const esc = s => String(s).replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));

function showTip(evt, html) {
  tip.innerHTML = html;
  tip.style.opacity = 1;
  const r = tip.getBoundingClientRect();
  let x = evt.clientX + 14, y = evt.clientY + 14;
  if (x + r.width > innerWidth - 8) x = evt.clientX - r.width - 14;
  if (y + r.height > innerHeight - 8) y = evt.clientY - r.height - 14;
  tip.style.left = x + 'px';
  tip.style.top = y + 'px';
}
const hideTip = () => { tip.style.opacity = 0; };

/* Hit areas are the full row/column band, not the mark, so nothing needs a
   pixel-accurate landing. */
function hoverable(el, html) {
  el.style.cursor = 'default';
  el.addEventListener('mousemove', e => showTip(e, html));
  el.addEventListener('mouseleave', hideTip);
  el.setAttribute('tabindex', '0');
  el.addEventListener('focus', e => {
    const b = el.getBoundingClientRect();
    showTip({clientX: b.left + b.width / 2, clientY: b.top + b.height / 2}, html);
  });
  el.addEventListener('blur', hideTip);
}

const svgEl = (n, a = {}) => {
  const e = document.createElementNS('http://www.w3.org/2000/svg', n);
  for (const k in a) e.setAttribute(k, a[k]);
  return e;
};

/* ---------------- KPIs ---------------- */
function kpis() {
  const t = D.totals;
  document.getElementById('subtitle').textContent =
    `${t.runs} CI runs · ${t.records} test executions · ${t.first} to ${t.last}`;
  const tiles = [
    {k: 'Overall pass rate', v: t.rate + '%', note: `${t.passed} of ${t.records} executions`, hero: true},
    {k: 'CI runs', v: t.runs, note: `${t.first} → ${t.last}`},
    {k: 'Test types', v: t.types, note: 'distinct named assertions'},
    {k: 'Green streak', v: t.streak, note: t.streak === 1 ? 'run, all tests passing' : 'runs, all tests passing'},
  ];
  document.getElementById('kpis').innerHTML = tiles.map(x =>
    `<div class="tile${x.hero ? ' hero' : ''}"><div class="k">${esc(x.k)}</div>` +
    `<div class="v">${esc(x.v)}</div><div class="note">${esc(x.note)}</div></div>`).join('');
}

/* ------------- Horizontal bars -------------
   One measure, nominal categories -> a single hue for every bar. Darkening
   by value would double-encode length as lightness. */
function bars() {
  const data = D.tests, ROW = 26, BAR = 13, L = 196, R = 104, TOP = 20;
  const h = TOP + data.length * ROW + 26;
  const svg = svgEl('svg', {viewBox: `0 0 860 ${h}`,
                            role: 'img', 'aria-label': 'Pass rate by test type'});
  const W = 860 - L - R;

  [0, 25, 50, 75, 100].forEach(p => {
    const x = L + W * p / 100;
    svg.appendChild(svgEl('line', {x1: x, x2: x, y1: TOP - 8, y2: TOP + data.length * ROW,
                                   class: p === 0 ? 'axisline' : 'gridline'}));
    const t = svgEl('text', {x: x, y: TOP + data.length * ROW + 16,
                             class: 'tick', 'text-anchor': 'middle'});
    t.textContent = p + '%';
    svg.appendChild(t);
  });

  data.forEach((d, i) => {
    const y = TOP + i * ROW, w = Math.max(W * d.rate / 100, 0);
    const g = svgEl('g', {class: 'row'});

    const lab = svgEl('text', {x: L - 10, y: y + BAR - 2, class: 'cat', 'text-anchor': 'end'});
    lab.textContent = d.test;
    g.appendChild(lab);

    // Track, then the value bar with a 4px rounded data-end at the baseline.
    g.appendChild(svgEl('rect', {x: L, y: y, width: W, height: BAR, rx: 4,
                                 fill: 'var(--grid)', opacity: 0.55}));
    if (w > 0) {
      g.appendChild(svgEl('rect', {x: L, y: y, width: Math.max(w, 4), height: BAR, rx: 4,
                                   fill: 'var(--series-1)'}));
    }
    const v = svgEl('text', {x: L + W + 10, y: y + BAR - 2, class: 'val'});
    v.textContent = d.rate + '%';
    g.appendChild(v);
    // Sample size next to the rate: 0% off one run is not the same claim as
    // 0% off twelve, and the bar length alone cannot say which this is.
    const n = svgEl('text', {x: L + W + 54, y: y + BAR - 2, class: 'val',
                             fill: 'var(--muted)'});
    n.textContent = `${d.pass}/${d.total}`;
    g.appendChild(n);

    const hit = svgEl('rect', {x: 0, y: y - 5, width: 860, height: ROW,
                               fill: 'transparent'});
    g.appendChild(hit);
    hoverable(g, `<b>${esc(d.test)}</b><br><span class="mono">${d.pass} / ${d.total}</span> runs passed` +
                 `<br><span class="mono">${d.rate}%</span> pass rate`);
    svg.appendChild(g);
  });
  document.getElementById('bars').appendChild(svg);
}

/* ------------- Line over time ------------- */
function line() {
  const suites = [...new Set(D.runs.map(r => r.label))];
  /* Fixed slot order, never cycled: a suite keeps its hue as others come and
     go. Past the four slots the tail goes gray rather than inventing a hue
     no one could tell from an existing one. */
  const SLOTS = ['var(--series-1)', 'var(--series-2)', 'var(--series-3)', 'var(--series-4)'];
  const colorOf = i => i < SLOTS.length ? SLOTS[i] : 'var(--muted)';
  document.getElementById('lineLegend').innerHTML = suites.map((s, i) =>
    `<span><i class="swatch" style="background:${colorOf(i)}"></i>${esc(s)}</span>`).join('');

  const Lp = 44, Rp = 92, TOP = 14, H = 210;
  const svg = svgEl('svg', {viewBox: `0 0 860 ${H + 46}`,
                            role: 'img', 'aria-label': 'Pass rate over time'});
  const W = 860 - Lp - Rp;
  const n = D.runs.length;
  const X = i => n === 1 ? Lp + W / 2 : Lp + W * i / (n - 1);
  const Y = v => TOP + (H - TOP) * (1 - v / 100);

  [0, 50, 100].forEach(p => {
    svg.appendChild(svgEl('line', {x1: Lp, x2: Lp + W, y1: Y(p), y2: Y(p),
                                   class: p === 0 ? 'axisline' : 'gridline'}));
    const t = svgEl('text', {x: Lp - 9, y: Y(p) + 4, class: 'tick', 'text-anchor': 'end'});
    t.textContent = p + '%';
    svg.appendChild(t);
  });

  suites.forEach((s, si) => {
    const pts = D.runs.map((r, i) => ({...r, i})).filter(r => r.label === s);
    if (pts.length > 1) {
      const path = svgEl('path', {
        d: pts.map((p, k) => `${k ? 'L' : 'M'}${X(p.i)},${Y(p.rate)}`).join(' '),
        fill: 'none', stroke: colorOf(si), 'stroke-width': 2,
        'stroke-linejoin': 'round', 'stroke-linecap': 'round'});
      svg.appendChild(path);
    }
    pts.forEach(p => {
      // 2px surface ring keeps overlapping markers separable.
      svg.appendChild(svgEl('circle', {cx: X(p.i), cy: Y(p.rate), r: 5,
                                       fill: colorOf(si), stroke: 'var(--surface-1)',
                                       'stroke-width': 2}));
    });
    // Direct-label the endpoint only.
    const last = pts[pts.length - 1];
    if (last) {
      const t = svgEl('text', {x: X(last.i) + 11, y: Y(last.rate) + 4, class: 'val'});
      t.textContent = s;
      svg.appendChild(t);
    }
  });

  // Crosshair band per run - the hit target is the whole column.
  D.runs.forEach((r, i) => {
    const bw = n === 1 ? W : W / (n - 1);
    const g = svgEl('g');
    g.appendChild(svgEl('rect', {x: X(i) - bw / 2, y: TOP - 10, width: bw,
                                 height: H - TOP + 24, fill: 'transparent'}));
    hoverable(g, `<b>${esc(r.label)}</b><br>${esc(r.date)} · <span class="mono">${esc(r.sha)}</span>` +
                 `<br><span class="mono">${r.pass}/${r.total}</span> passed · <span class="mono">${r.rate}%</span>`);
    svg.appendChild(g);
  });

  // Label first, last and any run that was not fully green.
  D.runs.forEach((r, i) => {
    if (i === 0 || i === n - 1 || r.rate < 100) {
      const t = svgEl('text', {x: X(i), y: H + 22, class: 'tick', 'text-anchor': 'middle'});
      t.textContent = r.date.slice(5);
      svg.appendChild(t);
    }
  });
  document.getElementById('line').appendChild(svg);
}

/* ------------- Status matrix -------------
   Status colors, so every cell also carries a glyph; color alone never
   encodes the result. */
function matrix() {
  const tests = D.tests.map(t => t.test);
  const runs = D.runs;
  const L = 196, CH = 21, TOP = 16;
  const CW = Math.max(24, Math.min(44, (860 - L) / runs.length));
  // Rotated date labels are ~32px long once turned, so the box has to
  // reserve that band or the scroll container crops them.
  const AXIS = 48, LABEL_Y = TOP + tests.length * CH + 20;
  const h = TOP + tests.length * CH + AXIS;
  const natural = L + runs.length * CW + 10;
  const svg = svgEl('svg', {viewBox: `0 0 ${natural} ${h}`,
                            role: 'img', 'aria-label': 'Test results per run'});
  svg.style.minWidth = natural + 'px';

  tests.forEach((t, r) => {
    const y = TOP + r * CH;
    const lab = svgEl('text', {x: L - 10, y: y + CH - 7, class: 'cat', 'text-anchor': 'end'});
    lab.textContent = t;
    svg.appendChild(lab);

    runs.forEach((run, c) => {
      const key = run.id + '|' + t;
      const has = key in D.cells;
      const ok = D.cells[key];
      const g = svgEl('g', {class: 'cell'});
      // 2px gap between fills.
      g.appendChild(svgEl('rect', {
        x: L + c * CW + 1, y: y + 1, width: CW - 2, height: CH - 3, rx: 4,
        fill: !has ? 'var(--grid)' : ok ? 'var(--good-wash)' : 'var(--critical-wash)',
        stroke: !has ? 'none' : ok ? 'var(--good)' : 'var(--critical)',
        'stroke-width': has ? 1 : 0, opacity: has ? 1 : 0.5}));
      if (has) {
        const gl = svgEl('text', {
          x: L + c * CW + CW / 2, y: y + CH - 7, 'text-anchor': 'middle',
          'font-size': 11, 'font-weight': 600,
          fill: ok ? 'var(--good)' : 'var(--critical)'});
        gl.textContent = ok ? '✓' : '✗';
        g.appendChild(gl);
      }
      hoverable(g, `<b>${esc(t)}</b><br>${esc(run.label)} · ${esc(run.date)}` +
                   `<br>${has ? (ok ? '✓ passed' : '✗ failed') : 'not run in this suite'}`);
      svg.appendChild(g);
    });
  });

  runs.forEach((run, c) => {
    const cx = L + c * CW + CW / 2;
    const t = svgEl('text', {x: cx, y: LABEL_Y, class: 'tick',
                             'text-anchor': 'middle',
                             transform: `rotate(-90 ${cx} ${LABEL_Y})`});
    t.textContent = run.date.slice(5);
    svg.appendChild(t);
  });
  document.getElementById('matrix').appendChild(svg);
}

/* ------------- Table twin ------------- */
function table() {
  const rows = D.tests.map(t =>
    `<tr><td>${esc(t.test)}</td><td class="num">${t.pass}</td>` +
    `<td class="num">${t.total}</td><td class="num">${t.rate}%</td></tr>`).join('');
  const runRows = D.runs.map(r =>
    `<tr><td><a href="${esc(r.url)}">${esc(r.label)}</a></td><td>${esc(r.date)}</td>` +
    `<td>${esc(r.sha)}</td><td class="num">${r.pass}</td><td class="num">${r.total}</td>` +
    `<td class="num">${r.rate}%</td></tr>`).join('');
  document.getElementById('tblTests').innerHTML =
    `<thead><tr><th>Test</th><th class="num">Passed</th><th class="num">Runs</th><th class="num">Rate</th></tr></thead>` +
    `<tbody>${rows}</tbody>`;
  document.getElementById('tblRuns').innerHTML =
    `<thead><tr><th>Run</th><th>Date</th><th>Commit</th><th class="num">Passed</th><th class="num">Tests</th><th class="num">Rate</th></tr></thead>` +
    `<tbody>${runRows}</tbody>`;
}

kpis(); bars(); line(); matrix(); table();

document.getElementById('foot').innerHTML =
  `Generated ${esc(D.generated)} from GitHub Actions JUnit artifacts. ` +
  `Only CI runs appear here - runs executed by hand on the lab host are not collected.`;

const tableBtn = document.getElementById('tableBtn');
tableBtn.addEventListener('click', () => {
  const on = tableBtn.getAttribute('aria-pressed') === 'true';
  tableBtn.setAttribute('aria-pressed', String(!on));
  document.getElementById('tableCard').classList.toggle('hidden', on);
});
document.getElementById('themeBtn').addEventListener('click', () => {
  const cur = document.documentElement.getAttribute('data-theme');
  const dark = cur ? cur === 'dark'
                   : matchMedia('(prefers-color-scheme: dark)').matches;
  document.documentElement.setAttribute('data-theme', dark ? 'light' : 'dark');
});
</script>
</body>
</html>
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="site/index.html")
    ap.add_argument("--limit", type=int, default=100)
    args = ap.parse_args()

    runs, records = collect(args.limit)
    if not runs:
        sys.exit("no runs with parsable JUnit artifacts found")
    data = aggregate(runs, records)

    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    # </script> inside the JSON would close the host tag early.
    payload = json.dumps(data, separators=(",", ":")).replace("</", "<\\/")
    out.write_text(HTML.replace("__DATA__", payload), encoding="utf-8")

    t = data["totals"]
    print(f"wrote {out}  ({t['runs']} runs, {t['records']} executions, "
          f"{t['types']} test types, {t['rate']}% overall)")


if __name__ == "__main__":
    main()

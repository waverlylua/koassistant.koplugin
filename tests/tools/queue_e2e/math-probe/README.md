# Genuine mathematical-layout tests

These are offline/native process tests using official KOReader v2026.07.1, not mocked widgets. The local provider returns `rich-math-fixture.txt`; it is a canned response, not model inference. No external AI provider is called.

After parent `setup_runtime.sh` and optional `install_package_runtime.py`, run:

    KOREADER_RUNTIME=/absolute/path/to/koreader python math-probe/run_rich_tests.py

Run from any directory. A fresh KO_HOME and PDF copy are created in this directory. The local mock listens on 127.0.0.1:8767. The real reader, durable queue, network subprocess, answer viewer, clipboard and native renderers are used; actions are driven by a late test patch calling production methods, not by human input. Separate CUA review covers actual native interactions.

Checks: original corner gesture is not overwritten; explicit corner assignment opens inbox; closing returns to unchanged page; actual HTTP answer raw bytes remain intact; rich HTML embeds PNG formulas; unsupported command remains visible; actual Copy button returns exact raw TeX; Text/Math round-trip; restart retains raw answer; no replay. Outputs include 600×800 actual answer-window screenshots for every HTML page and raw Text view, events.jsonl and provider receipts.

`corpus.json` is a 15-case geometry/fidelity set covering nested fractions, radicals, matrices, aligned lines, cases, sums/integrals/limits, inline equations and safe unsupported/malformed/wide fallback. Run the direct native raster probe from the KOReader runtime:

    KO_HOME=/absolute/test/profile SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software RICH_E2E_ROOT=/absolute/path/math-probe ./luajit /absolute/path/math-probe/probe_corpus.lua

It tests the installed plugin; override KOREADER_PLUGIN for another source checkout. Native formula PNGs are 2× supersampled and reported width/height are intended display sizes. `probe_bridge.lua` proves PNG data URI/resource-directory images render in bundled MuPDF HTML; direct SVG text/path works while SVG data URI does not.

Actual Android/AiPaper rendering, e-ink refresh, device keyboard/network and suspend remain unverified. This implements a bounded LaTeX subset, not a complete TeX engine. Compare pixels and original source, not just successful image generation.

The `probe_baseline.lua` fixture compares MuPDF image alignment properties. In the tested runtime, numeric negative vertical-align, middle/bottom/text-bottom and sub wrappers do not lower a tall inline formula to the surrounding prose baseline. This is a known cosmetic limitation; complex formulas read best as display math.

## Android Schur-complement regression

`probe_android_schur.lua` transcribes the failing formulas from Android screenshots
870/871, including semidefinite order, sized delimiters and pseudoinverses. It
also checks related order glyphs and keeps unsupported notation as source. Run
from the KOReader runtime with `KOREADER_PLUGIN` pointing to the checkout,
`SCHUR_OUTPUT` pointing to an existing output directory and a disposable `KO_HOME`.
Use `SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software EMULATE_READER_W=824
EMULATE_READER_H=1648`. It saves native PNGs and cold/warm timings in `results.json`.

For actual answer-window proof, put `android_schur_patch.lua` in the disposable
profile's `patches/2-schur-regression.lua` and launch the synthetic PDF using the
same environment. It loads `android-schur-fixture.txt`, explicitly reloads source
modules (avoiding an installed plugin's already-cached modules), normalizes the
font setting to 32 physical pixels and verifies that only the deliberate unknown
command falls back. It captures each page, reopens the answer, checks raw source
preservation and saves `viewer-results.json`. Check `viewer-error.txt` for failure;
this harness does not call any provider.

Pixel regression: in the 824×1648 fixture, the first equation on page 2 must remain
readable (about 217×43 layout pixels), rather than shrinking to about 30×6 pixels
at a MuPDF page boundary. Display-math images use block layout to preserve size;
this MuPDF version places those blocks at the left edge. Inline math is unchanged.

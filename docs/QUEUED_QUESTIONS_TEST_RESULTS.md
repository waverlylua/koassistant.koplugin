# Complete v3 verification — 2026-10-02

## Exact installable artifact

- File: `koassistant-queued-v3-rc2.zip`
- Plugin version: `0.23.0-queue.3`
- SHA-256: `304c0635378f1c0763448a32cee7c2c27d094867a863e64d323f94163bca02a7`
- Runtime source checkpoint: `a293814d5584d8a819892ca3019db4d43079d52d`
- Upstream base: `c801d04dd085f9d2f1c0fbd448317dcbf838f868`

The exact ZIP was installed into an isolated official KOReader runtime before final tests. Its hash matched before and after all tests. A second build produced byte-identical output. Later source changes are documentation only; no tested package bytes were replaced.

The build script refuses to overwrite an existing candidate. To reproduce its timestamps from a checkout containing this runtime code, set `SOURCE_DATE_EPOCH=1790960782` and run `python3 scripts/build_question_queue_zip.py /new/path/koassistant-v3.zip`. Newly added files must be tracked/staged; the script packages tracked files using upstream exclusions. No API credentials, personal configuration, test profile, test harness or fixture is in the install ZIP.

## Final runtime results

| Tier | Result |
|---|---|
| Core queue/transport, crash recovery and region PNG/HTTP | 31 checks passed: 18 flow, 4 recovery, 9 vision |
| Rich math, configured gesture, Copy/Text/Math and restart | 19 checks passed |
| Whole-page capture, follow-up, registered/recent prompts | 36 checks passed, plus HTTP body/count assertions |
| Native PNG encoder fault injection | 2 passed |
| Native mathematical corpus | 12 formulas rendered; unsupported, malformed and over-wide cases each gave an explicit source fallback |

Eleven total HTTP calls across these suites went to loopback mock providers. No real provider was contacted and no new request was submitted after restart. The regular flow retained exactly the explicitly attempted requests; cancellation and late callbacks could not revive cancelled jobs.

The extension tier verified whole original-page capture at a longest edge of 1800 pixels, byte-identical capture after actual zoom changes, correct source/image and previous answer at the follow-up HTTP boundary, immutable parent attempts, ancestor deletion safety, persistent lineage, registered prompt favorites, deduplicated recent wording, current-source binding, and duplicate callback guards.

## Unit, syntax and lint

- Prior queue/payload/OAuth integration coverage: 38 tests passed
- New two-dimensional math/parser/renderer coverage: 68 tests passed
- New page/follow-up/prompts/UI coverage: 23 tests passed
- Existing math compatibility: 22 tests passed; existing OAuth: 15 passed
- All 293 Lua files, including the final native test probes, parse under official KOReader's bundled LuaJIT
- Changed production Lua: Luacheck 1.2.0 reports 0 warnings, 0 errors, 0 fatal errors
- Python build/test scripts compile; runtime setup shell syntax passes
- Full unit suite: 125 discovered files, 5,379 passing per-file reported checks and one failing check. The repository mixes assertion counters and test-case counters, so this is not a uniform test-case count
- The sole failure is the native-search common-word wildcard assertion. It also fails on unmodified upstream in the same environment (117 files, 5,250 reported passing checks, one failure). No new failure remains

The runner's exit code alone was not treated as success. Logs and per-file outcomes were inspected; the known upstream failure is explicitly disclosed.

## Actual 600 × 800 UI and independent review

Actual KOReader answer-window screenshots demonstrate:

- Nested fraction `(1 + 1/2) / (1 - 1/3) = 9/4`
- Quadratic formula with the radical rule spanning the discriminant
- A true 2 × 2 matrix, including a fractional entry, and the correct determinant
- Aligned expansion/derivative lines with a shared equals column
- Piecewise cases with a full-height brace
- Summation limits and integral bounds
- Explicit unsupported-command fallback, with exact original TeX available in Text mode and Copy

The response is a clearly labeled local test fixture, not real model inference. Screenshots are the native KOReader application, not design mockups or a web typesetting service.

Independent hands-on review also covered saved/custom selection submission, continuing reading while pending, no forced answer popup, source-page preservation, compact favorites/recent/all/manage prompt controls, saving a prompt without sending a request, full original-page images despite a partial viewport, and a new follow-up that leaves the original answer unchanged. The outgoing whole-page PNG was decoded and inspected. No release-blocking UX issue remained in these desktop-tested flows.

The inbox action is configurable through KOReader's Gesture Manager. No existing user binding is changed by installation. Both process-driven dispatch and a separate actual native UI corner assignment/tap were verified. The manual path was Settings → Taps and gestures → Gesture manager → Tap corner → Bottom right → General → KOAssistant: AI answer inbox. Tapping the corner opened the inbox; Close returned to page 5 at the same position. This is desktop mouse/touch-emulation verification, not physical target-device hardware verification.

## Math implementation and boundaries

This is an offline **two-dimensional LaTeX-subset typesetter**, not a full TeX/KaTeX/MathJax engine. It measures KOReader's native FreeType glyphs, lays out mathematical structures and rules, and encodes PNGs in memory with the bundled library. There is no equation network request, browser engine, external executable or temporary equation file.

Unsupported syntax and oversized expressions remain visible as original source. The original stored answer and copied text are untouched. Tall inline formula images sit slightly high because bundled MuPDF ignores image vertical-alignment alternatives; display math is recommended for complex expressions. This is a cosmetic limitation, not missing notation or clipping. Formula images are not selectable text; Copy answer or Text mode retains access to the source.

## Environment and unverified boundaries

Official KOReader v2026.07.1 Linux x86_64 on Debian 13, bundled SDL3/LuaJIT/MuPDF/FreeType/liblodepng. Runtime tarball SHA-256: `299aadb28147a25e9432ced1214ea444a4184393b5ae97cf42402c8a61b1a1b0`. Reproducible harnesses and synthetic fixtures are under `tests/tools/queue_e2e/`, including `math-probe/` and `extension-probe/`.

No real login credentials, paid provider request, model-quality evaluation, physical e-ink hardware, Android emulator/device or target-device suspend/wake cycle was used. Account-specific provider acceptance, real vision inference, Android lifecycle/storage behavior and AiPaper typography/refresh remain unverified. These are experimental desktop-tested packages. Installation and hardware acceptance instructions are in `QUEUED_QUESTIONS.md`.

## Preserved earlier checkpoints

The previous distributions remain unchanged:

- Text v1 RC2: `9e45fef2e1c0b2a2ac685a91d8675032d2cce89921428140725f42ff3b3d8a85`
- Vision v2 RC2: `5fbb6f3def33972602f90a6fa5e7919b6ddfb617f14a0075c15b68cf86344b88`

Their math renderer was the earlier readable-HTML conversion, with slashed fractions and flattened matrices. Complete v3 replaces that display path with actual two-dimensional layout.

## v3 RC3 responsiveness correction (2026-10-02)

A native reproducer isolated the repeated-open stall to KOReader's Markdown
parser scanning base64 PNG image attributes. For an 824 × 1648 screenshot-like
convex-analysis answer, the old path spent 6.82 seconds in Markdown conversion;
math rasterization took 44 ms, MuPDF layout 4 ms, and page scrolling 17 ms.
Cached formula images did not help because Markdown ran again on every open.

The fixed path removes those payloads only while Markdown is parsed and restores
the exact image tags before layout. Same-run native measurements were 78 ms for
first viewer creation and 23 ms for reopen, with approximately 1 ms in Markdown.
An independent actual-reader run measured 78 ms cold and 24–25 ms on repeated
fresh opens. A separate original-package stress fixture independently reproduced
4.38–4.57 second reopens, while scrolling took 1–3 ms. These are Linux runtime
measurements, not a claim about exact target-Android speed.

Additional checks cover plain-English control answers, repeated Text/Math
switching, source/HTML preservation, font-size invalidation and persistence,
width/layout changes, and defensive nonblocking response-pipe cleanup. The latter
fix checks both fcntl calls, closes the owned pipe exactly once, unschedules the
actual callback, and prevents dispatch after synchronous cancellation. Ten new
fault-injection tests pass; nine fail against the original code. This transport
hardening is not claimed as the demonstrated cause of the Android ANR.

New targeted image-protection tests pass 7/7; queued UI tests pass 7/7. Full unit
suite was rerun with the native filesystem dependency against both unchanged
7768c67 and the revised source: both have the same sole native-search wildcard
failure. No new aggregate failure was introduced. Physical Android hardware
remains unverified here; the screenshot and subsequent user report motivate the
fix, while the native reproducer establishes the eliminated multi-second stall.

Reproduction: `tests/integration/native/answer_performance.lua` runs from an
official KOReader directory with a fresh `KO_HOME`, `KOREADER_PLUGIN` pointing at
the unpacked plugin, and the SDL dummy video/software renderer. It uses synthetic
text only, with no network request or provider credentials. A configurable
2-second ceiling fails the test if a tested action stalls again.

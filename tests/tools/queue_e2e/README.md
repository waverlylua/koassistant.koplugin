# KOAssistant question queue verification

## Environment

- Official KOReader v2026.07.1 Linux x86_64 portable release, SDL3 and bundled LuaJIT, MuPDF/PDF engine and libraries
- Vendor source: https://github.com/koreader/koreader/releases/tag/v2026.07.1
- Runtime archive SHA-256: `299aadb28147a25e9432ced1214ea444a4184393b5ae97cf42402c8a61b1a1b0`
- Linux cloud execution workspace; native X11 cloud desktop for CUA clicks, and SDL dummy video driver for reproducible process integration
- No KOReader core patch, root install, provider account, real API key or paid request was needed
- The six-page PDF is synthetic. No private user document was transmitted
- Provider fixture binds loopback only. Its dummy key is not a real credential

## Reproduce

Prerequisites: Linux x86_64 with glibc >=2.35; Python 3, curl, tar/xz and sha256sum. KOReader's runtime archive supplies its Lua/SDL/native libraries.

1. `./setup_runtime.sh /path/to/koassistant.koplugin`
2. `python3 run_process_tests.py`
3. To test an actual distribution archive instead of source: `python3 install_package_runtime.py /path/to/release.zip`, then `KOREADER_RUNTIME="$PWD/package-runtime" python3 run_process_tests.py`
4. Native PNG fault regression: from `lib/koreader`, run `KO_HOME=/absolute/path/to/encoder-home SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software ./luajit /absolute/path/to/test_encoder_native.lua`

`run_process_tests.py` creates a new per-run configuration directory and independent PDF copy. Existing records are kept. It starts and stops its own local provider on port 8766. Every HTTP request is logged in `logs/provider-process.jsonl`; `logs/process-summary.json` is written only after all assertions pass. No real provider URL is used.

## What each test tier means

### Actual UI interaction

A real KOReader X11 window was operated with CUA clicks, drags and keypresses. Checks covered:

- PDF sentence selection, Queue question, saved Explain action
- A custom typed question and captured selection included in the HTTP request
- Closed prompt panels, continued reader navigation during a 20-second HTTP delay
- Inbox result, original book/page, read/unread count, and explicit answer opening
- Markdown, superscripts and display formula rendering using the existing viewer
- A discreet pending/completed reader badge after fixing the default-footer case
- PDF region crop via two corner taps; the actual PNG sent in the HTTP request was decoded and visually checked, and contains exactly the selected formula lines
- Independent narrow-screen/error/retry review has its own screenshots

The automation profile reduced KOReader's hold-selection threshold to 30 ms to match CUA's drag gesture duration. This is a test-profile setting, not a product code change. Native application screenshots were saved with KOReader's Alt+Shift+G shortcut. Some filenames use the desktop's local timezone rather than UTC.

### Real-process integration with synthetic calls

This is not a unit-test mock and is not a manual click test. A late startup test patch calls the production plugin methods inside the actual KOReader application. The actual PDF renderer, ReaderUI/UIManager, subprocess HTTP transport, JSON journal, fsync and filesystem writes all run normally against the local HTTP server.

Checks cover source-page precedence over a different footer page, immutable captured text and model, multiple sequential jobs, page movement and event-loop ticks while HTTP is pending, no completion popup or position change, distinct answers and origins, read state, queued cancellation without dispatch, running cancellation without late revival, HTTP 503 without automatic retry, explicit retry, and process termination/recovery.

The final request-count assertions require exactly five HTTP calls in the normal/cancel/fail/retry flow. The crash scenario adds one running request, SIGKILLs the reader process group with another job still queued, and restarts it. Both jobs must become interrupted and the provider count must remain unchanged after restart.

### Native encoder fault injection

Uses the actual KOReader BlitBuffer/PNG encoder, not a stub. A read-only stale previous PNG must never be returned as a newly captured region. An unwritable output directory must fail closed. The initial implementation failed the stale-file case; the corrected implementation passes both cases.

## Limits

- Android/AiPaper physical hardware, Android process lifecycle, storage permission/SAF behavior, e-ink refresh characteristics, and suspend/wake behavior on the target devices are not hardware-verified
- No Android SDK/emulator or attached device was available in the execution environment
- Local OpenAI-compatible transport and payload correctness are verified; real AI answer quality, provider billing, real vision inference and account authentication are not exercised by this fixture
- Only KOReader v2026.07.1 is claimed as tested; older releases are unverified
- Automated screenshots are genuine rendered KOReader output with synthetic method calls; CUA/native-click screenshots are identified separately

## Device acceptance checklist

On each intended Android/AiPaper device: install the tested KOReader/plugin versions, use a disposable document and local/mock or separately authorized provider, queue two selected-text questions on different pages, close the panel and turn pages, verify the badge and both origins, cancel a pending request, test failed-request explicit retry, background/suspend while in flight, kill/reopen KOReader and verify no silent resubmission, then test a cropped formula image if using the region-enabled build.

## Final verified distribution archives (2026-10-02)

- `koassistant-queued-text-v1-rc2.zip`: SHA-256 `9e45fef2e1c0b2a2ac685a91d8675032d2cce89921428140725f42ff3b3d8a85`; 18 flow checks and 4 recovery checks passed after installing these exact archive bytes
- `koassistant-queued-vision-v2-rc2.zip`: SHA-256 `5fbb6f3def33972602f90a6fa5e7919b6ddfb617f14a0075c15b68cf86344b88`; the same 22 checks plus 9 region-selector/PNG/HTTP checks passed, plus both native PNG failure regressions
- Text run: exactly 6 provider requests including the intentionally killed request. Vision run: exactly 7 including one image request. Reopening after the kill submitted no duplicate request
- Region phase uses the real two-corner selector callbacks, real reader view rendering, real saved-prompt menu callback, production vision payload builder and actual queued HTTP subprocess; only method invocation is synthetic
- The actual image received at the HTTP boundary was a correctly cropped 517 × 104 PNG with the two page-3 formula lines
- Initial defects found and verified fixed: invisible badge with default footer mode, wrong origin page in continuous PDF view, stale image reuse after native PNG write failure

## Complete v3 (2026-10-02)

`koassistant-queued-v3-rc2.zip`, version `0.23.0-queue.3`, SHA-256 `304c0635378f1c0763448a32cee7c2c27d094867a863e64d323f94163bca02a7`, was installed before its final reruns: 31 core/recovery/vision checks, 19 rich-math/gesture/copy/restart checks, 36 extension checks, 2 native encoder faults. All 11 HTTP calls were loopback fixtures; restart produced none. The native corpus rendered 12 supported formulas and retained source for 3 unsupported/malformed/oversized cases.

Additional reproducible fixtures are in `math-probe/` and `extension-probe/`; read their READMEs. The mathematical display is now a genuine local two-dimensional subset, not the older slash/flattened HTML conversion. Its tall-inline baseline limitation and hardware/provider limits are documented in the delivery verification report.

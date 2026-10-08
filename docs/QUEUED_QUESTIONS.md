# Queued AI questions

Plugin-only extension of [zeeyado/koassistant.koplugin](https://github.com/zeeyado/koassistant.koplugin), based on upstream commit `c801d04`. No KOReader core patch, separate service or new API credential is required.

## Which build?

- **Complete v3 RC5** (`0.23.0-queue.3-rc5`): the current build, adding readable wrapping for wide display formulas and OpenAI Subscription image-question routing to RC4's two-dimensional math, whole-page/region images, saved-answer follow-ups, prompt favorites/recent wording and assignable inbox gesture
- **Text v1** (`0.23.0-queue.1`): selection → saved/custom prompt → continue reading → durable answer inbox
- **Vision v2** (`0.23.0-queue.2`): all text features, plus two-corner capture of a displayed PDF region and an image-capable model request

Only one build should be installed at a time. RC5 replaces earlier code and retains ordinary KOAssistant settings and the existing RC4 per-document inbox. The storage transition introduced in RC4 still ignores older test inboxes, never migrating or deleting them. The frozen v1/v2 RC2 packages are previous checkpoints; their math display was the simpler readable-HTML conversion. The richer formula typesetting described below is in v3.

## Install

1. Close KOReader. Back up your existing `plugins/koassistant.koplugin` folder and your KOReader settings.
2. Extract the chosen ZIP into KOReader's `plugins` folder. It contains exactly one `koassistant.koplugin/` folder. Replace the code files inside your existing plugin directory; preserve personal `configuration.lua`, `apikeys.lua`, `custom_actions.lua`, `custom_models.lua`, `behaviors/` and `domains/` if you have them. The supplied ZIP has no credentials or device-specific test settings.
3. Restart KOReader. Keep using your already-configured provider and model. A local provider works for text too.
4. The builds were tested with official **KOReader v2026.07.1, Linux x86_64, Debian 13**. Use that or a current compatible release. Earlier versions have not been validated; no older minimum-version claim is made. The image selector needs touch or mouse input.
5. Do not install an ordinary upstream plugin update over this experimental build if you want to retain these added controls. The separate inbox data survives replacing the plugin code, but an upstream build will not show it.

## Text: send and keep reading

1. Select a passage and tap **Queue question**.
2. The chooser shows its source page and selected-text preview. The compact chooser starts with your registered selection-prompt favorites/shortcuts. Tap a saved prompt to queue it, or choose **Write a question…** and tap **Queue**. **All registered prompts…** shows the other compatible prompts. **Recent questions…** opens up to five distinct custom questions for review/editing before sending; **Save as prompt…** registers new wording and adds it to your shortcuts.
3. The prompt closes immediately. Turn pages, dismiss panels or queue a second passage. Jobs run one at a time.
4. The reading status bar shows counts such as **AI: 2 ready · 1 pending**. Failed or interrupted jobs add **need attention**. A small corner indicator is used when the status bar is hidden. Neither completion nor failure opens a modal answer window.
5. Open **Tools → KOAssistant → AI answer inbox**. Rows show the question/prompt, source page and passage excerpt (or an image ID), with state at the right. Unread answers are bold.
6. Tap a ready row to read the answer. **Copy answer** copies its actual text; **Text / Math** switches presentation; **Back to inbox** returns to the list; **Close** returns to reading. **Ask a follow-up…** queues a new question about that saved answer and its original source.
7. Hold any row for its original question, provider/model, cancellation, explicit retry or removal. Removing a terminal job asks for confirmation and deletes its stored passage, answer and separate image files.

### Open the inbox from a corner gesture

The manually verified path is **Settings → Taps and gestures → Gesture manager → Tap corner → Bottom right → General → KOAssistant: AI answer inbox**. You may choose another supported gesture instead. No existing bindings are changed automatically. The action is also listed in KOAssistant's Shortcuts manager. It opens the inbox, never an unsolicited answer, and closing it returns to the current reading page. The status-bar counts themselves remain display-only.

### Follow up on a saved answer

Open an answer, tap **Ask a follow-up…**, then choose a registered prompt or enter/edit a question. This queues an independent new request using the original saved source, the earlier answer and the same saved model. It does not read the current page or require the original book to stay open. The original passage or image is sent again; a follow-up is a new potentially billable model call. Deleting the parent does not break an already-saved child.

The context includes at most eight recent exchanges and 24 KB of thread text (original source/image are additional). An earlier answer longer than 16 KB is excerpted; the editor explicitly reports shortened history. Saved answers are never truncated in the inbox. The follow-up operates on the whole saved answer; selecting a sub-passage within that answer is not implemented.

Saved actions that need whole-book extraction, current-page text, other highlights, notebooks, live reading statistics, library data, tools or local handlers remain in normal Chat/Action. Their exclusion prevents silently running them with incomplete context. Selection-only saved/custom prompts retain normal action model/provider pins, behavior, domain and applicable per-book preferences. Book-info privacy and spoiler posture are resolved when the job is queued.

## Images: a PDF region or whole page

1. In KOAssistant settings choose a supported image-capable model: OpenAI or OpenAI Subscription GPT-4o/4.1/5/6, Anthropic Claude 3/4, or Gemini 1.5/2/3 families. RC5 converts saved image messages to the Responses image format for subscription requests. Availability, account entitlement, limits and billing remain provider-specific; live subscription acceptance has not been verified. Other providers and unknown model families remain outside this build's conservative gate. Unsupported custom-question destinations are reported before you type a question.
2. In a PDF/page-based document, open **Tools → KOAssistant → Queue PDF region question…**.
3. Tap two opposite corners around the formula, diagram or passage. Swipe or press Back to cancel. The underlying page is frozen before selector controls are drawn.
4. Choose a saved prompt or type a question. Saved explicit model/provider pins are respected; otherwise the current model is used. Automatic action-tier switching is suppressed for image jobs. Text-only models are rejected before sending.
5. Continue reading. The cropped PNG and source coordinates stay with that job even when pages turn. A crop spanning two pages records a page range; the UI does not assume that the footer's current page is the selected page.

For a complete page, choose **Queue whole PDF page [number]…** instead. It renders that exact original PDF page independently of the current viewport, crop, zoom or reflow, with a longest edge of 1800 pixels. Confirm the page number in the prompt chooser, especially in continuous view where two pages may be visible. It sends one page image, not the PDF file.

For a region question, only the selected displayed pixels are sent, not the full PDF. The maximum encoded PNG is 4 MiB. Image jobs use one vision call without book tools or web-search routing. The PNG is saved as a separate binary file and referenced by the document manifest. Native encoder failures fail closed; an old temporary PNG is never reused as a new capture.

Wire formats follow the providers' official guides: [OpenAI](https://developers.openai.com/api/docs/guides/images-vision), [Anthropic](https://platform.claude.com/docs/en/build-with-claude/vision), [Gemini](https://ai.google.dev/gemini-api/docs/image-understanding).

## Durability, cancellation and charges

- A job freezes selected text/image, document identity and positions, prompt, resolved provider/model, destination and message body. It does not read a later page when dispatched.
- Jobs progress through queued → running → completed/failed/cancelled/interrupted. Send intent is flushed and synced before the network request begins.
- The worker belongs to the KOReader session, not the prompt or answer dialog. Closing those dialogs, turning pages or switching books does not cancel it.
- **Cancel** stops local work. It cannot revoke a delivered request or guarantee that the provider will not bill it.
- **Retry** is always explicit and warns about possible duplicate billing. The queue route disables automatic token-budget retries. Cancelling during asynchronous OAuth refresh cannot trigger a later paid request; concurrent refresh subscribers share one token refresh, and cancelling detaches only that job.
- After restarting KOReader, unfinished jobs become **Interrupted**. No job is silently replayed. After suspend, the active job needs an explicit retry; never-started jobs from the same session can continue on wake.
- This is not an Android service or OS daemon. Requests run only while KOReader and its network subprocesses can run. Hardware/OS power management can interrupt them. Network failures are saved instead of forcing a Wi-Fi dialog.
- If storage fails, new sends stop. Existing answers remain readable. **Retry saving inbox (no new request)** retries local persistence before queued work continues. Corrupt or unknown-format inbox files are left untouched and block new submissions.

## Data and backup

The new inbox lives in `ai-inbox/` under KOReader's data directory (normally `/sdcard/koreader/ai-inbox/` on Android). Each document has one authoritative `<document-id>/document.json` manifest. Questions, source excerpts, answers and reasoning are Markdown files under each `question-<id>/` directory; images are separate binary files. The manifest contains metadata and request structure with file references, never inline image data. There is no global index and no SQLite database. List views load metadata; opening, retrying or following up loads the selected question's payload.

Document IDs use KOReader's partial-MD5 fingerprint when the source is available, with a deterministic path-based fallback for unavailable sources. This is a fingerprint, not a full-file cryptographic identity. IDs remain attached to captured jobs. Payload changes are written to new files before atomically replacing the document manifest; the manifest is the commit point. Writes are synchronous and intended for one KOReader process, not concurrent writers. A directory/file-sync failure blocks further sending until local saving is retried.

The old `settings/koassistant_question_inbox.json` test journal is left untouched and is not imported or migrated. The new inbox starts empty.

API-key and OAuth credential fields are excluded; credentials are resolved from ordinary live settings at dispatch. Protect the entire directory like your private reading notes.

**Ordinary KOAssistant chat backup does not include this inbox.** Close KOReader and copy the entire `ai-inbox/` directory when backing up or moving devices. Removing a terminal question commits its removal in the manifest before cleaning its payload files. Empty document manifests preserve the ID high-water mark. Unreferenced files from interrupted writes are harmless and are not automatically imported.

## Formula presentation

The revised build uses a **local two-dimensional LaTeX-subset typesetter**. It is not a full TeX, KaTeX or MathJax engine. A bounded Lua parser lays out measured KOReader FreeType glyphs and mathematical rules into in-memory PNGs; KOReader's existing HTML viewer displays them. It uses only libraries and fonts already shipped with KOReader. There is no equation-rendering server, JavaScript engine, TeX installation, network request, or temporary equation file.

Supported notation includes:

- Stacked and nested fractions, binomial coefficients, superscripts/subscripts and primes
- Square/indexed roots with a rule spanning the full radicand
- Matrix row/column grids with parentheses, square brackets, braces or determinant bars
- `aligned`, `align`, `gathered`, `split`, and simple `array` layouts; piecewise `cases`
- Sums/products with stacked display limits, integrals with bounds, limits, common functions, Greek letters and mathematical symbols
- Text/roman, italic and bold styles; common blackboard/calligraphic letters; vector, hat, bar, dot and underline accents
- `$...$`, `$$...$$`, `\(...\)`, and `\[...\]` delimiters; code spans and fences are left alone

Wide display expressions automatically wrap at safe top-level clause, relation and binary-operator boundaries. Matrix cells, fractions, scripts, paired delimiters, text labels and numeric literals stay intact, and continuation lines retain their operators. Inline expressions do not acquire display-style line breaks. Unsupported commands/environments, malformed input, and indivisible expressions that cannot fit this view still show an explicit **Math source** fallback with the original expression. Nothing is silently flattened or dropped to imitate a successfully typeset equation. Any size reduction remains capped at 15%; long proofs should use shorter aligned lines. General macros, package loading, TikZ, arbitrary TeX spacing/column specifications and full TeX line breaking are unsupported.

The Math/Text button switches the display only. Original answer text and exact LaTeX remain unchanged in the inbox and **Copy answer**. Formula images cannot be selected as ordinary text; use Copy answer or Text mode. The bundled HTML engine ignores image-baseline alignment: tall inline fractions sit slightly high within prose. Use display math (`$$...$$` or `\[...\]`) for complex expressions. Android uses the same built-in font/bitmap libraries, but target-device typography and e-ink behavior still need hardware acceptance.

## Test and reproduction notes

- Per-document storage: 19 real-runtime integration checks, including failure/retry, no-resend restart, lazy payloads, independent follow-ups, corrupt manifests, path safety and UTF-8 previews
- Queue state machine: 18 focused tests (serial/frozen jobs, cancel races, explicit retry, restart, suspend, storage failure/recovery, removal)
- Payload/privacy/vision: 9 tests (credential-field exclusion, frozen destination, image envelopes, privacy/metadata, continuous-PDF page provenance)
- OAuth queue integration: 11 tests with real runtime/query/OAuth modules and mocked dispatch, including shared refresh, cancellation and rotated credentials
- Offline two-dimensional math: 68 parser/layout/renderer/fallback checks; existing math compatibility: 22 passed
- Whole-page capture, follow-up snapshots, registered/recent prompts and picker UI: 23 checks
- Existing OAuth tests: 15 passed
- All Lua source parses under the bundled KOReader LuaJIT
- Real KOReader subprocess/mock-HTTP E2E covers page turns, closing panels/documents, multiple jobs, cancel, error and retry, process restart and no automatic duplicate submissions
- Real UI tests include saved/custom selection questions, inbox/answer rendering, working copy and navigation, and PDF region capture; the decoded transmitted PNG was checked for the requested formula region and absence of overlay controls
- Native PNG fault injection verifies stale read-only output cannot be reused and an unwritable destination fails closed

The repository-wide unit suite was run against both upstream and this branch in the same environment. With the official runtime's real filesystem library loaded, one unrelated baseline failure remains in `test_book_tools` (the native-search common-word phrase fallback). It reproduces on unmodified RC3 `7c6abf6`. A standalone run without the filesystem setup produces additional environment-dependent failures and is not the acceptance run. The queue-focused tests and storage inventory checks pass; this is not represented as a clean all-upstream-tests result.

No paid provider request, physical e-ink device, or Android background/suspend run was used for these checks. The local mock validates request routing, lifecycle and UI, not a real model's answer quality or account-specific acceptance. The delivery test manifest records the exact tested ZIP hashes and final per-build results.

Focused tests, from the checkout:

    luajit tests/unit/test_question_queue.lua
    luajit tests/unit/test_question_payload.lua
    luajit tests/unit/test_question_auth.lua
    luajit tests/unit/test_math_layout.lua
    luajit tests/unit/test_question_page.lua
    luajit tests/unit/test_question_followup.lua
    luajit tests/unit/test_question_prompts.lua
    luajit tests/unit/test_question_ui.lua
    lua tests/run_tests.lua --unit

The full test suite requires its documented JSON/filesystem test dependencies. Reproducible runtime/mock-HTTP assets are in `tests/tools/queue_e2e/`. Build the current installable ZIP with `scripts/build_question_queue_zip.py`; the text-only option is `--text-only`.

## v3 RC3: faster equation answers and larger text

Update the same `koassistant.koplugin` folder, preserving your existing personal
configuration/keys and KOReader settings. Fully quit and restart KOReader so it
loads the new Lua modules. The version is `0.23.0-queue.3-rc3`.

Opening an answer with equations no longer sends the embedded PNG data through
KOReader's Markdown parser. The old path could take several seconds on every
open, even when all formula images were cached. The revised path temporarily
replaces the image tags with short tokens, converts the surrounding Markdown,
and restores the identical image tags before layout. Reading/copying/storing the
original answer is unchanged; no request is repeated when an answer is opened.

The screenshot's `\succeq`, `\preceq`, `\bigl`/`\bigr`, and `\dagger` notation is
supported, including pseudoinverse and Schur-complement formulas. Full TeX is
still not supported; unsupported notation continues to show its original source.

In an answer, use the top-left gear → **Font Size** to enlarge its text and
formulas together (up to 32). This now persists when you close/reopen an inbox
answer. **Alignment** also persists. Changing font size retains rendered math.
The answer's gear shows relevant display controls only. For overall KOReader
menu/button scaling, use KOReader's own display/DPI setting separately.


## v3 RC4: per-document Markdown inbox

Install RC4 into the same `koassistant.koplugin` folder and fully restart KOReader.
The version is `0.23.0-queue.3-rc4`. On Android the usual plugin destination is
`/sdcard/koreader/plugins/koassistant.koplugin/`.

Each document has one `document.json`. Each question has `question.md`, `source.md`,
`answer.md` when complete, optional `reasoning.md`, and `source.png` for a captured
image. Exact provider request text is stored in additional `request-*.md` files.
Changed payloads use content-suffixed filenames so replacing the manifest cannot
expose a mixture of old and new content. The manifest always identifies the
current files. There is no global JSON index, SQLite database or automatic migration.

The RC3 fast formula-rendering path and saved font/alignment settings are retained.
Old test data remains in place; only the new `ai-inbox/` appears in this build.

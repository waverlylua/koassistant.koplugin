# Experimental fork guide

This is a personal, independently maintained experiment based on
[zeeyado/koassistant.koplugin](https://github.com/zeeyado/koassistant.koplugin)
at upstream commit `c801d04dd085f9d2f1c0fbd448317dcbf838f868` (v0.23.0).
It is not an official upstream release. There is no promised support, release
schedule, or compatibility guarantee. Please do not treat fork-specific behavior
as an upstream defect.

The original authors and contributors retain credit. The inherited source,
copyright notices, and [GNU General Public License v3](LICENSE) are preserved.
This fork's modifications are distributed under the same license.

## What this fork adds

The current development snapshot is `0.23.0-queue.3-rc5`:

- Queue a selected passage, PDF region, or complete PDF page and keep reading.
  Requests run serially; completed answers appear in an inbox without opening a
  modal dialog. Saved prompt favorites, recent question wording, and an
  assignable inbox gesture are included.
- Save each document's questions and answers in an atomic, file-based
  `ai-inbox/` directory. An interrupted request requires an explicit retry;
  restarting the reader never silently resends it.
- Ask a follow-up using the original saved source and previous answer.
- Render a bounded LaTeX subset locally, including fractions, matrices, scripts,
  and safe wrapping of wide display formulas. The original answer text is
  retained for copying and explicit source fallback.
- Route saved image questions to supported vision-provider payloads, including
  the OpenAI Subscription Responses image format added in RC5.

See [usage, storage, and privacy details](docs/QUEUED_QUESTIONS.md) and the
[RC5 release notes](QUEUED_QUESTIONS_RC5.txt).

## Experimental limits

- RC5 was exercised with a native Linux KOReader runtime and synthetic/mocked
  requests. Physical Android/e-ink hardware and live OpenAI Subscription image
  requests have not been verified. Provider entitlement, server acceptance,
  model availability, and limits remain account-dependent.
- The renderer is not full TeX. Unsupported or indivisibly oversized notation
  remains visible as its original source instead of being silently altered.
- The queue is part of KOReader, not an Android background service. Closing,
  suspending, or losing power/network can interrupt requests.
- Cancelling local work cannot revoke an already delivered request. Retrying or
  following up can incur another provider charge. A follow-up resends its saved
  text or image source to the selected provider.
- The full historical unit run retained one known upstream/baseline book-tools
  failure; the focused queue/math checks passed. Earlier verification details
  are in [the test record](docs/QUEUED_QUESTIONS_TEST_RESULTS.md). Those results
  are historical evidence, not a claim that every device or live provider works.

## Installation and data

1. Fully close KOReader. Back up its settings, the current plugin folder, and
   the complete `ai-inbox/` directory.
2. Install a reviewed fork ZIP containing one `koassistant.koplugin/` folder
   into KOReader's `plugins/` directory. Replace code while retaining your own
   `configuration.lua`, `apikeys.lua`, custom actions/models, behaviors, and
   domains. Keep only one active copy of the plugin.
3. Restart KOReader and check the version shown in the plugin metadata.

Personal credentials, settings, books, captured pages, answers, logs, and runtime
profiles do not belong in a source commit or release archive. Sample
configuration values and test credentials are placeholders only. Supply your
own credentials privately through the plugin's normal configuration.

The inbox can contain private reading material and source images. It is outside
the plugin's code folder, and ordinary KOAssistant chat backup does not include
it. Close KOReader before copying the entire inbox for backup or migration.
Earlier test inbox formats are neither automatically imported nor deleted.

## Online update status

Fork-specific online updating is not configured or verified in this snapshot.
The inherited update constants still point at the upstream repository. Accepting
an upstream update can replace this fork's added code; use manual fork packages
for now and consider disabling automatic update checks in KOAssistant settings.

Before advertising an online update channel for this fork, a release must point
at the intended fork repository, use a version/tag pair recognized by the
updater, attach the expected plugin ZIP, and pass an upgrade test that preserves
personal configuration and the separate inbox. A public repository by itself
does not establish a working update channel.

## Building and checking a source checkout

The [test README](tests/README.md) distinguishes offline unit checks from live
provider tests. Do not run provider tests without intending to use your own
account and potentially incur charges. Native reproductions use synthetic data
and the fixtures in `tests/tools/queue_e2e/`.

From a clean, reviewed checkout, build a local install ZIP with:

```sh
python3 scripts/build_question_queue_zip.py /path/to/koassistant-queue.zip
```

The builder uses tracked filenames and excludes the repository's development
tests and screenshots. Keep local logs and runtime folders untracked. Inspect
the resulting archive before publication;
release exclusions are not a substitute for checking both the source tree and
its publishable Git history for credentials and private data.

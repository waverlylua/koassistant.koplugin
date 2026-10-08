# Original-page, follow-up and prompt integration

After the parent runtime setup and installing the candidate plugin, run:

    KOREADER_RUNTIME=/absolute/path/to/koreader python extension-probe/run_extension_tests.py

The runner uses a fresh KO_HOME and PDF copy, real KOReader PDF renderer/UIManager/queue/HTTP transport and loopback mock provider on 127.0.0.1:8768. It calls production methods through a test-only late patch; it does not simulate a paid provider or prove real hardware behavior.

It checks full original-page dimensions/cap, byte-identical capture after actual zoom operations, reading position/original source separation, saved registered prompt persistence and shared favorites, duplicate-name rejection, saved/custom callback duplicate guards, two follow-ups with preserved original image and preceding answers at the HTTP boundary, ancestor deletion safety, root/source lineage after restart, bounded/deduplicated Recent wording and no restart resubmission. Exactly 3 requests should reach the local provider: original page, first follow-up, second follow-up. Additional prompt/dedup jobs are explicitly paused/cancelled and never sent.

Outputs: native original-page PNG, flow/restart logs, events.jsonl and provider receipts. Synthetic files and screenshots are ignored by git. Never run these fixtures against a real provider or a user's personal profile.

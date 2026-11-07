# Windows recurrence diagnostics

The installed Windows supervisor keeps an append-only JSONL history at `$PROJECT_ROOT/runtime/events.jsonl`. Open `History.cmd` for the latest 100 records. `Status.cmd` reports observer health separately from blocker health. Logs stay on this PC; they are not uploaded automatically.

## What the history can establish

- A candidate ad window was first observed, became visible, became hidden, reappeared, or was destroyed. Initial enumeration is not proof of a new creation event.
- A recognized web child appeared later or a candidate's structure changed. Each inspection obtains fresh metadata instead of reusing a previous child list.
- The owning Kakao process and its version, the window's generated identifier, size and structural evidence. Ownership does not identify which process called a show/hide operation.
- A persistent popup matched the existing upstream pattern, a blocker restart was requested, that restart succeeded or failed, and a later visibility observation followed it. A later disappearance is correlation, not proof that the restart caused it.
- The hosts file's hash, size and three configured ad-domain mappings changed. DNS protection was lost or restored. The file writer remains `unknown`; the observer does not enable Windows security auditing or infer that Kakao rewrote the file.

Records include UTC time and monotonic elapsed time so a wall-clock correction does not silently reorder a running observer's history. Process/window identities are scoped to their observed lifetime; a reused window handle must not inherit previous ad evidence.

## Response to a returning popup

The observer uses public, process-scoped [Windows events](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwineventhook) and a periodic rescan. It records candidates conservatively. Automatic reapplication requires the strict legacy popup structure and an exact ad-specific marker (`MOMENT 광고` or `AdFit NAS Advertisement`) to remain visible for at least one second. The generic `Chrome Legacy Window` caption alone is insufficient. Off-screen or DWM-cloaked windows do not qualify. Unknown candidates and banner candidates are logged without triggering this response.

The supervisor restarts only its verified upstream blocker, with at least 60 seconds between automatic requests and at most three requests in ten minutes within an observer session. Each tracked window instance has a maximum of three attempts. It does not close KakaoTalk, implement a new hide rule, change hosts, request administrator access, or disable normal chat notifications. Reapplication runs during the supervisor's normal loop, so this is recovery after observation, not a guarantee of preventing the first visible frame. Blocker crash backoff and rollback remain separate from this recovery.

If the same popup survives recovery, use the correlated history to investigate the upstream selector. Do not broaden matching to every blank window or every browser control. DNS changes that require repair still need normal administrator authorization.

## Privacy and limits

The new journal stores no conversation text, chat titles, contacts, screenshots, page URLs, executable paths or full hosts contents. The native observer only compares known web-control captions with exact structural/ad markers and discards the text. Existing `maintenance.log` error messages may still contain local paths, so review files before sharing them.

The current journal and three rotated files are retained, each with a roughly 1 MiB size limit. Rotation bounds disk use rather than guaranteeing a number of days. Observer failures and dropped events are reported in health; a running blocker alone does not prove that logging is active.

A visibility event does not identify the caller that changed the window. A hosts-file change does not identify its writer. UI content replaced entirely inside an existing WebView may produce no relevant native window event. Very short-lived windows and periods when the observer is stopped may be missed. The observer does not record network traffic or reconstruct internal Kakao code paths.

## Follow-up evidence

Read the records around the user's reported time, including the preceding baseline and any repair result. Check `Diagnostics` in status for running state, errors and dropped events. Compare the run identifier, window identifier and process lifetime before calling an event a recurrence. Keep synthetic test events separate from on-device ad evidence. Never publish raw runtime files without inspection.

Useful event names include `window_first_observed`, `window_notification`, `window_structure_changed`, `window_hidden_observed`, `window_reappeared`, `window_removed_observed`, `repair_requested`, `repair_restart_result`, `repair_observation`, `repair_exhausted`, `hosts_changed`, `dns_protection_lost` and `dns_protection_restored`. A failed hosts read produces `dns_protection_unknown`; a subsequent successful read produces `dns_protection_verified`, without inventing a deletion or restoration. `window_notification` records a received native event; its fresh snapshot may already reflect a later state. `window_removed_observed` includes a reason such as destruction, missing handle or no longer matching the candidate structure.

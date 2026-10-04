# Fach — Arbeitsstand und Agentenregeln

Native German macOS folder organizer in Swift 6.2/SwiftUI, macOS 26+, Apple Silicon. Repository root contains Package.swift; no web frontend.

## Responsibilities
- Sources/FachCore: scan protections, immutable snapshots, no-overwrite file operations, SQLite journal, crash recovery, per-operation undo, verified Trash backup.
- Sources/FachAI: bounded content extraction, checked descriptor reads, Ollama local-only model validation, Jev closed-choice classification, cloud structured naming, per-run budget reservations.
- Sources/FachApp: German onboarding/settings, Keychain, security-scoped folder bookmarks, Ollama launch/download management, previews, review/questions, animated movement, history.
- Packaging and scripts: Sandbox arm64 .app and DMG, optional Developer ID/notarization.
- Brand: generated icon and visual brand board.

## Product constraints
Prefer existing folders. Direct files default; recursion opt-in. Significant structure changes require evidence and separate review/confirmation. Never overwrite or permanently delete. Rename/Trash explicitly confirmed. User context affects Active/Archive/Open. Cloud consent per run; summary-only option. Default budget $0.10, no automatic paid retries. Remote/cloud Ollama models forbidden for local privacy. Do not read credentials or private files for development tests. Use synthetic fixtures.

Read $CODEX_HOME/CODEX.md if present. Follow user-selected skills, economical subagent choices. All app-facing copy German, understandable without engineering knowledge. Use native UI controls and system colors/type, reduced motion and keyboard access.

## Build and validation
swift test
bash scripts/build-app.sh
bash scripts/package-dmg.sh

Current regression suite: 24 AI XCTest tests plus 64 Core Swift Testing tests. Snapshots include filesystem ctime to reject same-size rewrites with restored mtime. Current app UI tested in sandbox with synthetic demo corpus and a scoped external fixture; sorting, undo, real Trash and restore verified. Keychain may already contain a user key; never print it. Local Ollama text and LLaVA image smoke tests used only synthetic files and generated artwork. Small local models made inaccurate targets, and their recommendations remain manual-only. Cloud paths tested by injected transport; no private cloud smoke runs.

Local distribution default is ad-hoc signed, not notarized. Do not claim Developer ID or notarization unless verified. Update this file when architecture, safety behavior, commands or validation state changes.

## Repository
GitHub: https://github.com/Maxi139/Fach, public, default branch main. CI runs synthetic tests and builds an ad-hoc-signed preview DMG on macos-26. Never commit API keys, user content, signing identities or local build folders.

## Analysis persistence
Unfinished non-demo analyses and manual choices are checkpointed locally in Application Support/Fach/analysis-draft.json (0600), incrementally after each file. Restore validates snapshots and resets cloud consent. Changed files need fresh confirmation. Legacy recovered-assignments.json imports through a fresh metadata scan without model calls; it remains local and must never be published. Explicit inspector confirmation approves an existing target without changing the picker. User data and recovery copies stay outside this repository.

## Bulk review
“Vorschläge sortieren …” offers one grouped review and explicit consent for all known existing-folder targets, including low-confidence local/recovered suggestions. Batch sorting only moves the reviewed IDs; no inferred targets or new folders. Protected, completed, directory, and restored changed files stay excluded. Recommendation.requiresIndividualReview is optional for legacy draft compatibility; explicit individual assignment clears it. Bulk approvals persist before the existing journaled move/undo path runs.

## Selection and delete marks
File cards support additive checkbox/click selection, Shift ranges and Command-A scoped to the focused collection; file-kind/status/search filters prune hidden selections and inspector focus. Group/All checkboxes and a searchable folder popover assign multiple files once. Inspector is hidden by default; one counted sort action opens a review with file/group opt-outs. “Ohne Ziel” selects the unassigned filter. Delete toggles persisted markedTrashIDs and never executes Trash directly. Marks exclude moves; assigning/keeping clears them. Trash centrally validates current snapshots/protection and removes only successful requested items, preserving all other analysis. Rename/undo refresh via draft snapshot restoration + fresh metadata merge, preserving untouched choices and costs. Native synthetic multi-selection, Delete/unmark, grouped assignment, selected sorting, Trash and undo were verified.

## Keyboard stack review
“Stapelmodus” (Command-Shift-J) snapshots the visible, selectable, unmarked files in a session-only FileDeck. Large native Quick Look previews, left/right navigation, F folder search, Delete marks and immediately advances, assignment persists and advances. No file operations run in stack mode; existing overview review performs moves/Trash. Folder search uses stable URL path identities and validates every clicked, Enter, or delayed unique result against current matches. Auto-choice is cancellable and rechecks after 400 ms. A window-scoped NSEvent monitor handles keys even when Quick Look takes focus, bypasses editable fields/open sheets, ignores repeated Delete, and removes itself on teardown. Reduced motion is respected. Native synthetic tests verified rec→Rechnungen, two-result list and keyboard selection, empty results, cancellation, mark/advance, and overview marks. Demo testing leaves the saved real draft unchanged.

## Folder-aware sorting
FolderKnowledge reads bounded direct child file names (256 folders, 1024 examined entries/256 references each), never contents or symlinks, and rejects package/project targets including .icon. ExistingFolderPlanner recognises exact sidecars, conservative DaVinci still-series collections, distinctive project/OCR names and genuinely generic media folders. No arbitrary format-only routing into projects. “Ziele finden” creates local suggestions with OCR; a screenshot folder addition must cover at least three unmatched captures and accepting it assigns its covered IDs without another model run. Analysis retains current manual/null/Trash choices, processes missing or stale targets only, reuses validated evidence and provides bounded destination filename examples to models. Folder purposes are derived from curated plans or confirmed model descriptions, never raw OCR/text/PDF excerpts when summary-only mode is active. Cloud consent explicitly discloses those examples. Naming is opt-in in settings; unknown importance does not force a target question.

All moves now require explicit current-signature manual/batch approval; high confidence alone never bypasses review. Batch review includes accepted new targets and labels them “Wird neu angelegt”. Missing formerly existing targets are not recreated. ReviewedSortingPlan resolves untrusted local JSON atomically, bounds fields, protects paths/targets and produces proposals only. --sorting-plan imports into a fresh metadata scan while preserving current manual choices; --replace-delete-marks additionally clears marks only when explicitly requested. No Desktop file names, thumbnails or personal plan are committed. User-authorized local Desktop inspection/curated plan data is stored privately outside the repo; development regression fixtures remain synthetic.

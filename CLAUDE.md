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

Current regression suite: 19 AI XCTest tests plus 36 Core Swift Testing tests. Snapshots include filesystem ctime to reject same-size rewrites with restored mtime. Current app UI tested in sandbox with synthetic demo corpus and a scoped external fixture; sorting, undo, real Trash and restore verified. Keychain may already contain a user key; never print it. Local Ollama text and LLaVA image smoke tests used only synthetic files and generated artwork. Small local models made inaccurate targets, and their recommendations remain manual-only. Cloud paths tested by injected transport; no private cloud smoke runs.

Local distribution default is ad-hoc signed, not notarized. Do not claim Developer ID or notarization unless verified. Update this file when architecture, safety behavior, commands or validation state changes.

## Repository
GitHub: https://github.com/Maxi139/Fach, public, default branch main. CI runs synthetic tests and builds an ad-hoc-signed preview DMG on macos-26. Never commit API keys, user content, signing identities or local build folders.

## Analysis persistence
Unfinished non-demo analyses and manual choices are checkpointed locally in Application Support/Fach/analysis-draft.json (0600), incrementally after each file. Restore validates snapshots and resets cloud consent. Changed files need fresh confirmation. Legacy recovered-assignments.json imports through a fresh metadata scan without model calls; it remains local and must never be published. Explicit inspector confirmation approves an existing target without changing the picker. User data and recovery copies stay outside this repository.

## Bulk review
“Vorschläge sortieren …” offers one grouped review and explicit consent for all known existing-folder targets, including low-confidence local/recovered suggestions. Batch sorting only moves the reviewed IDs; no inferred targets or new folders. Protected, completed, directory, and restored changed files stay excluded. Recommendation.requiresIndividualReview is optional for legacy draft compatibility; explicit individual assignment clears it. Bulk approvals persist before the existing journaled move/undo path runs.

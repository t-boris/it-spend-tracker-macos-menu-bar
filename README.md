# IT Spend Tracker (macOS menu bar)

A personal, local-only macOS menu bar app that aggregates spending across the user's IT and AI services (Fly.io, Google/Firebase, Vercel, Neon, OpenAI/ChatGPT, Anthropic, etc.), broken down per service and per API key, with monthly history and totals, so the user can decide which services to keep or cancel. An AI assistant guides the user through connecting each new service (what credentials are needed and how to obtain them).

## Problem

Personal IT/AI spending is growing and scattered across many provider dashboards. There is no single place to see how much each service and each key costs, how costs change month to month, and which subscriptions are worth keeping.

## Scope

IN (v1): macOS menu bar app whose icon opens one resizable window (DEC-029); list of connected services with per-service and total spend; per-key breakdown where the provider exposes it (name, last used, expiry, spend); monthly history and trends; user-selectable subset of services for totals; AI-guided onboarding of a new service; local-only storage, nothing exposed externally. OUT (v1): web/mobile versions, multi-user or sharing, cloud sync, automatic cancellation of services, key rotation/management actions. Budgets and notifications are out of v1 (DEC-002); all amounts are USD (DEC-005).

## Specification

The confirmed brief, decisions and requirements are in [`docs/features/it-spend-tracker-macos-menu-bar/`](docs/features/it-spend-tracker-macos-menu-bar/overview.md). Open this folder in MarkView to continue them.

### Requirements

- REQ-001 Menu bar presence
- REQ-002 Per-service and total spend
- REQ-003 Per-key details
- REQ-004 Monthly history
- REQ-005 AI-guided service onboarding
- REQ-006 Local and secure credential storage
- REQ-007 Manual subscription entry
- REQ-008 In-panel warning indicators
- REQ-009 Scheduled background refresh with manual refresh
- REQ-010 Prepaid credits, balances and token usage
- REQ-011 Built-in v1 connectors and their data capabilities
- REQ-012 AI-proposed connectors for services without a built-in connector
- REQ-013 Key tags with per-tag totals
- REQ-014 Resizable main window
- REQ-015 Cost breakdown inside a service
- REQ-016 Key detail page
- REQ-017 Usage metrics for providers without money data
- REQ-018 Spending chat
- REQ-019 Daily history, trends and month forecast

Decisions DEC-001..DEC-041 in `decisions/`; provider API facts in `references/SRC-002.md`.

## Install (local, launch at login)

```sh
scripts/install.sh        # Release build → /Applications/IT Spend Tracker.app, launched, registered as a login item
```

Run it again to update. "Launch at login" can be changed in Settings → Startup.

## Build and run

Requirements: macOS 15+, Xcode 16+ (tested with Xcode 27), [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
scripts/build.sh          # generate the Xcode project and build (Debug)
scripts/build.sh test     # run unit tests
open build/Build/Products/Debug/ITSpendTracker.app
```

- Data: `~/Library/Application Support/ITSpendTracker/spend.store`; credentials: macOS Keychain.
- Debug builds accept `-DemoData YES` to show sample data from an in-memory store (no network, no Keychain).
- Real Claude Code / Codex CLI checks (use your subscription): `TEST_RUNNER_ITS_CLI_INTEGRATION=1 xcodebuild -project ITSpendTracker.xcodeproj -scheme ITSpendTracker -derivedDataPath build test -only-testing:ITSpendTrackerTests/AssistantIntegrationTests`
- After adding UI strings: build, then `xcrun xcstringstool sync ITSpendTracker/Resources/Localizable.xcstrings --stringsdata <build/**/*.stringsdata>` and add the Russian text in `scripts/ru_translations.py`.

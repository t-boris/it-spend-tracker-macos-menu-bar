---
type: plan
feature: it-spend-tracker-macos-menu-bar
title: IT Spend Tracker v1 (macOS menu bar)
issues:
  - id: I-1
    title: "App shell: menu bar item, panel, local data store and Russian localization"
    summary: Create the native macOS menu bar app with a status item and popover panel, the local database in Application Support (services, keys, monthly spend, subscriptions, credits, refresh status) and a String Catalog with Russian UI strings. No server or web UI is exposed. This is the foundation that all other issues build on.
    requirements: [REQ-001, REQ-006]
    decisions: [DEC-013, DEC-018, DEC-019]
    github: 1
  - id: I-2
    title: Keychain credential storage and service removal
    summary: "Add a Keychain wrapper scoped to the app for storing provider credentials, and make sure no secret is ever written in plain text. Implement removal of a service: after the user confirms, delete its Keychain items and all of its stored spend, key, credit and history data. Credentials and spend data may be sent only to the provider being queried."
    requirements: [REQ-006]
    decisions: [DEC-013, DEC-011]
    github: 2
  - id: I-3
    title: Connector framework and refresh scheduler
    summary: "Define the connector protocol. Each connector declares its capabilities (spend, per-key details, balance, token usage, daily granularity, backfill depth) and gets native credential form fields. Build the refresh engine: refresh every 4 hours, on launch and on wake when data is older than 4 hours, and on the manual Refresh button. Refreshes run per service and are isolated from each other; on failure the last known data is kept and the service gets an error indicator. The panel shows cached data immediately, with a last-updated time per service. On connection, up to 12 months of history are backfilled where the provider allows it."
    requirements: [REQ-009, REQ-004]
    decisions: [DEC-006, DEC-009, DEC-012, DEC-015]
    github: 3
  - id: I-4
    title: Provider research and connectors for OpenAI and Anthropic
    summary: "Confirm each provider's admin/usage API capabilities: which keys are required, per-key data and history depth. Then implement the OpenAI and Anthropic connectors, covering spend, per-key details (name, last used, expiry, spend), token usage and credit purchases/balances where available. If a provider turns out to have no usable API, it moves to manual entry."
    requirements: [REQ-002, REQ-003, REQ-004, REQ-010, REQ-011]
    decisions: [DEC-012, DEC-007, DEC-008, DEC-015, DEC-017, DEC-020]
    github: 4
  - id: I-5
    title: Provider research and connectors for Vercel, Neon, Fly.io and Google Cloud/Firebase
    summary: Confirm each provider's billing API capabilities, then implement connectors for Vercel, Neon and Fly.io, plus Google Cloud/Firebase via the Cloud Billing BigQuery export. Fields a provider does not expose are shown as 'no data', never as zero. A provider found to lack a usable API falls back to manual entry.
    requirements: [REQ-002, REQ-003, REQ-004, REQ-011]
    decisions: [DEC-012, DEC-015, DEC-020]
    github: 5
  - id: I-6
    title: Manual subscriptions and prepaid credit purchases
    summary: "Add create, edit and delete for manual subscriptions: name, USD amount, monthly or yearly period, start date and optional end date. Each charge counts in the month it falls due. Price changes take effect from a chosen date, so earlier months keep the old amount. Add manual entry of prepaid credit purchases, which count as spend in the month of purchase; consumption and balance are shown separately."
    requirements: [REQ-007, REQ-002, REQ-004, REQ-010]
    decisions: [DEC-001, DEC-005, DEC-014, DEC-007, DEC-008, DEC-021]
    github: 6
  - id: I-7
    title: "Panel UI: services, totals, per-key details and monthly history"
    summary: Build the panel views. The service list shows current-month USD spend for each service. The user selects which services are included in the total, and the total updates accordingly. A service's detail view lists its keys with name, last used, expiry and spend, showing unavailable fields as unavailable. Monthly history charts show spend per service and in total, and distinguish zero spend from missing data.
    requirements: [REQ-001, REQ-002, REQ-003, REQ-004, REQ-010]
    decisions: [DEC-005, DEC-015, DEC-018]
    github: 7
  - id: I-8
    title: Warning indicators
    summary: Flag keys that expire within 14 days, both on the key and on its service. Flag a service when its month-to-date spend exceeds the previous month's spend over the same number of days by more than 20% and by at least $5; when daily data is unavailable, compare against a prorated previous-month total. The menu bar icon shows a cue when any warning is active. There are no notifications and no budgets.
    requirements: [REQ-008]
    decisions: [DEC-002, DEC-010]
    github: 8
  - id: I-9
    title: AI-guided onboarding via Claude Code / Codex CLI
    summary: Add a setting to choose Claude Code or Codex CLI, and detect whether the selected CLI is installed and signed in, with install and sign-in guidance when it is not. The CLI runs non-interactively in print mode with all tools disabled, from an empty temporary directory. It receives only the service name, account identifier and connector metadata, and its output is shown as guidance text only. Credentials are entered in native connector forms and never reach the CLI. Services without a connector are routed to manual entry.
    requirements: [REQ-005, REQ-006, REQ-012]
    decisions: [DEC-003, DEC-004, DEC-011, DEC-012, DEC-022]
    github: 9
updated: 2026-09-30
epic: 10
---

# Implementation plan — IT Spend Tracker (macOS menu bar)

## I-1: App shell: menu bar item, panel, local data store and Russian localization (#1)

Create the native macOS menu bar app with a status item and popover panel, the local database in Application Support (services, keys, monthly spend, subscriptions, credits, refresh status) and a String Catalog with Russian UI strings. No server or web UI is exposed. This is the foundation that all other issues build on.

Requirements: REQ-001, REQ-006
Decisions: DEC-013, DEC-016

## I-2: Keychain credential storage and service removal (#2)

Add a Keychain wrapper scoped to the app for storing provider credentials, and make sure no secret is ever written in plain text. Implement removal of a service: after the user confirms, delete its Keychain items and all of its stored spend, key, credit and history data. Credentials and spend data may be sent only to the provider being queried.

Requirements: REQ-006
Decisions: DEC-013, DEC-011

## I-3: Connector framework and refresh scheduler (#3)

Define the connector protocol. Each connector declares its capabilities (spend, per-key details, balance, token usage, daily granularity, backfill depth) and gets native credential form fields. Build the refresh engine: refresh every 4 hours, on launch and on wake when data is older than 4 hours, and on the manual Refresh button. Refreshes run per service and are isolated from each other; on failure the last known data is kept and the service gets an error indicator. The panel shows cached data immediately, with a last-updated time per service. On connection, up to 12 months of history are backfilled where the provider allows it.

Requirements: REQ-009, REQ-004
Decisions: DEC-006, DEC-009, DEC-012, DEC-015

## I-4: Provider research and connectors for OpenAI and Anthropic (#4)

Confirm each provider's admin/usage API capabilities: which keys are required, per-key data and history depth. Then implement the OpenAI and Anthropic connectors, covering spend, per-key details (name, last used, expiry, spend), token usage and credit purchases/balances where available. If a provider turns out to have no usable API, it moves to manual entry.

Requirements: REQ-002, REQ-003, REQ-004
Decisions: DEC-012, DEC-007, DEC-008, DEC-015

## I-5: Provider research and connectors for Vercel, Neon, Fly.io and Google Cloud/Firebase (#5)

Confirm each provider's billing API capabilities, then implement connectors for Vercel, Neon and Fly.io, plus Google Cloud/Firebase via the Cloud Billing BigQuery export. Fields a provider does not expose are shown as 'no data', never as zero. A provider found to lack a usable API falls back to manual entry.

Requirements: REQ-002, REQ-003, REQ-004
Decisions: DEC-012, DEC-015

## I-6: Manual subscriptions and prepaid credit purchases (#6)

Add create, edit and delete for manual subscriptions: name, USD amount, monthly or yearly period, start date and optional end date. Each charge counts in the month it falls due. Price changes take effect from a chosen date, so earlier months keep the old amount. Add manual entry of prepaid credit purchases, which count as spend in the month of purchase; consumption and balance are shown separately.

Requirements: REQ-007, REQ-002, REQ-004
Decisions: DEC-001, DEC-005, DEC-014, DEC-007, DEC-008

## I-7: Panel UI: services, totals, per-key details and monthly history (#7)

Build the panel views. The service list shows current-month USD spend for each service. The user selects which services are included in the total, and the total updates accordingly. A service's detail view lists its keys with name, last used, expiry and spend, showing unavailable fields as unavailable. Monthly history charts show spend per service and in total, and distinguish zero spend from missing data.

Requirements: REQ-001, REQ-002, REQ-003, REQ-004
Decisions: DEC-005, DEC-015, DEC-016

## I-8: Warning indicators (#8)

Flag keys that expire within 14 days, both on the key and on its service. Flag a service when its month-to-date spend exceeds the previous month's spend over the same number of days by more than 20% and by at least $5; when daily data is unavailable, compare against a prorated previous-month total. The menu bar icon shows a cue when any warning is active. There are no notifications and no budgets.

Requirements: REQ-008
Decisions: DEC-002, DEC-010

## I-9: AI-guided onboarding via Claude Code / Codex CLI (#9)

Add a setting to choose Claude Code or Codex CLI, and detect whether the selected CLI is installed and signed in, with install and sign-in guidance when it is not. The CLI runs non-interactively in print mode with all tools disabled, from an empty temporary directory. It receives only the service name, account identifier and connector metadata, and its output is shown as guidance text only. Credentials are entered in native connector forms and never reach the CLI. Services without a connector are routed to manual entry.

Requirements: REQ-005, REQ-006
Decisions: DEC-003, DEC-004, DEC-011, DEC-012

## Implementation status (2026-09-30)

All issues I-1..I-9 are implemented in `ITSpendTracker/` (Xcode project generated from `project.yml`).
Research (SRC-002) moved Neon and Fly.io to manual entry (REQ-011); new services can get an
AI-proposed, user-approved connector (DEC-022, REQ-012). UI is Russian and English (DEC-018, supersedes DEC-016).
After first real use (2026-09-30): usage cost is spend and the billing mode is removed (DEC-023); subscriptions on any
service (DEC-026); breakdown by model/line item and project (DEC-027, REQ-015); key tags (DEC-024, REQ-013);
resizable window (DEC-025, REQ-014); GitHub connector (DEC-028).
Later the same day: GitHub (all organizations), Neon (usage + ≈ cost), Google Cloud (one key, several export datasets, keys with requests
and ≈ cost per key), console links, local install with launch at login (DEC-028..DEC-037).
Spending chat added 2026-10-01 (DEC-038, REQ-018).
Verification: 96 unit tests (`scripts/build.sh test`) plus opt-in real-CLI tests
(`TEST_RUNNER_ITS_CLI_INTEGRATION=1`), and visual checks of the panel with `-DemoData YES` (debug builds).

# IT Spend Tracker (macOS menu bar)

A personal, local-only macOS menu bar app that aggregates spending across the user's IT and AI services (Fly.io, Google/Firebase, Vercel, Neon, OpenAI/ChatGPT, Anthropic, etc.), broken down per service and per API key, with monthly history and totals, so the user can decide which services to keep or cancel. An AI assistant guides the user through connecting each new service (what credentials are needed and how to obtain them).

## Problem

Personal IT/AI spending is growing and scattered across many provider dashboards. There is no single place to see how much each service and each key costs, how costs change month to month, and which subscriptions are worth keeping.

## Scope

IN (v1): macOS menu bar app with a popover/panel; list of connected services with per-service and total spend; per-key breakdown where the provider exposes it (name, last used, expiry, spend); monthly history and trends; user-selectable subset of services for totals; AI-guided onboarding of a new service; local-only storage, nothing exposed externally. OUT (v1): web/mobile versions, multi-user or sharing, cloud sync, automatic cancellation of services, key rotation/management actions. Open: budgets/alerts, manual entry for services without billing APIs, currency handling.

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

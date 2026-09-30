---
type: feature
id: it-spend-tracker-macos-menu-bar
title: IT Spend Tracker (macOS menu bar)
status: exploring
owner: Boris Tsekinovsky
created: 2026-09-30
provenance: Created from the new-project intake
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: known
  Permissions: n/a
  Failure Scenarios: known
  Data Model: known
  Notifications: known
  Security: known
  Analytics: n/a
  Dependencies: known
  Acceptance Criteria: known
understanding_notes:
  Primary Workflow: Подключение через AI-помощника, фоновое обновление по расписанию + кнопка «Обновить», просмотр в панели меню.
  Data Model: Сервисы, ключи, ручные подписки, помесячная история, только USD.
  Notifications: Только визуальные индикаторы в панели.
  Problem: Расходы на IT/AI-сервисы разбросаны по многим панелям провайдеров.
  Target Users: Один пользователь — владелец Mac.
  Permissions: Однопользовательское локальное приложение.
  Failure Scenarios: При сбое обновления сохраняются последние данные и показывается индикатор ошибки; детали — на ревью.
  Security: Локальное хранение, секреты в защищённом хранилище, не передаются AI.
  Analytics: Не применимо.
  Dependencies: API провайдеров, локальные Claude Code / Codex CLI.
  Acceptance Criteria: Критерии заданы в требованиях.
questions_left: 0
confirmed: 2026-09-30
---

# IT Spend Tracker (macOS menu bar)

## Idea

A personal, local-only macOS menu bar app that aggregates spending across the user's IT and AI services (Fly.io, Google/Firebase, Vercel, Neon, OpenAI/ChatGPT, Anthropic, etc.), broken down per service and per API key, with monthly history and totals, so the user can decide which services to keep or cancel. An AI assistant guides the user through connecting each new service (what credentials are needed and how to obtain them).

## Problem

Personal IT/AI spending is growing and scattered across many provider dashboards. There is no single place to see how much each service and each key costs, how costs change month to month, and which subscriptions are worth keeping.

## Scope

IN (v1): macOS menu bar app with a popover/panel; list of connected services with per-service and total spend; per-key breakdown where the provider exposes it (name, last used, expiry, spend); monthly history and trends; user-selectable subset of services for totals; AI-guided onboarding of a new service; local-only storage, nothing exposed externally. OUT (v1): web/mobile versions, multi-user or sharing, cloud sync, automatic cancellation of services, key rotation/management actions. Open: budgets/alerts, manual entry for services without billing APIs, currency handling.

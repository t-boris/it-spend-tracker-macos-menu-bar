---
type: feature
id: tags-for-services-and-provider-items
title: Tags for Services and Provider Items
status: implemented
owner: Owner
created: 2026-11-08
provenance: Created from the quick feature intake
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: known
  Permissions: n/a
  Failure Scenarios: known
  Data Model: known
  Notifications: n/a
  Security: known
  Analytics: known
  Dependencies: known
  Acceptance Criteria: known
intake: quick
questions_left: 0
issue: "#14"
understanding_notes:
  Problem: Пользователь прямо запросил теги для сервисов и элементов провайдера; существующие требования охватывают только ключи.
  Target Users: Функция расширяет существующий сценарий пользователя локального приложения.
  Primary Workflow: Обзор и план задают редактирование тегов, общие подсказки, просмотр участников и переход к объектам; код уже реализует этот сценарий для ключей.
  Permissions: Локальное редактирование тегов не требует новых разрешений провайдера.
  Failure Scenarios: Обзор определяет сохранение назначений при исчезновении объектов, обработку переименований, отсутствующей стоимости и пересечений расходов.
  Data Model: Код хранит теги отдельно от обновляемых ключей. Обзор задаёт независимые назначения, идентичность без месяца и миграцию существующих тегов.
  Notifications: Уведомления не входят в область функции.
  Security: Локальное хранение подтверждено существующей реализацией; обзор исключает синхронизацию тегов с провайдерами.
  Analytics: Код уже считает теги за текущий месяц независимо от включения сервиса в общий итог. Обзор определяет приоритет суммы сервиса и запрет суммирования при неразрешимых пересечениях.
  Dependencies: Проверены хранение, редактор тегов, Tags view и разбивки account/project/lineItem. Новые возможности коннекторов исключены.
  Acceptance Criteria: Критериев обзора и существующего плана достаточно для подготовки спецификации. Дополнительных решений владельца продукта не требуется.
---

# Tags for Services and Provider Items

## Idea

Extend the existing tag system so users can organize whole services and provider-exposed items using one shared tag vocabulary.

## Problem

Key-only tagging cannot classify whole subscriptions or spending represented by projects, accounts, models, and other provider breakdown items.

## Scope

Generalize tag persistence, editing, suggestions, and the Tags view to tracked services, keys, and existing provider breakdown items. Preserve existing assignments and current-month reporting. Exclude provider-side tag synchronization, new resource discovery, and historical tag reporting.

## Analysis

Existing documentation limits tags to keys: docs/features/it-spend-tracker-macos-menu-bar/requirements/REQ-013.md and decisions/DEC-024.md. ITSpendTracker/Persistence/Models.swift stores KeyTagRecord separately from refreshed keys; SpendStore.swift normalizes assignments and supplies tag suggestions. UI/Forms.swift and UI/KeyDetailView.swift provide key tag editing. App/AppModel.swift and Domain/TagTotals.swift aggregate current-month key costs across connected services; UI/TagsView.swift lists members, unavailable costs, and estimates. Domain/Breakdown.swift already defines account, project, and line-item dimensions. Persistence/Models.swift stores breakdowns by month, dimension, label, and amount, without stable provider item IDs; SpendStore.swift replaces refreshed rows. UI/ServiceDetailView.swift displays those breakdowns without tag editing. Implementation therefore needs generalized tag targets, refresh-independent assignments, and aggregation that handles overlapping cost views.

## Assumptions

Made by the AI where the request left a choice open; correct them in the discussion.

- “Service” means an individual tracked service/account, including manual services; “provider elements” means keys and breakdown items already exposed by its connector.
- Servers and other resources are taggable when represented in existing provider data; adding resource discovery or new connector capabilities is outside this release.
- Tags remain local app metadata and are not synchronized with provider-side labels.
- Current-month reporting remains the default, and tag membership does not depend on the service's inclusion in the main spending total.
- Different tags may overlap financially; their totals are not additive.
- When overlap cannot be resolved from available data, an unavailable combined total is preferable to a misleading sum.

## Acceptance Criteria

- [ ] Users can add and remove free-text tags on tracked services, existing keys, and every provider breakdown item displayed by the app; existing tags are suggested across all target types.
- [ ] Tag input trims whitespace, ignores empty entries, and deduplicates case-insensitively. Assignments remain independent; tagging a service does not automatically tag its children.
- [ ] Assignments persist across restarts, refreshes, and month changes. Identity includes the tracked service and target type, using a provider ID when available; otherwise breakdown identity uses dimension plus exact label, excluding month.
- [ ] Existing key tags migrate without loss. Identically named targets in different services or dimensions do not share assignments. Removing a service deletes its assignments.
- [ ] Temporarily missing targets retain their assignments and appear as unavailable; their previous spend is not reused as current-month spend. Label-only targets that are renamed are treated as new targets.
- [ ] The Tags view lists tagged targets with their type, parent service, and current-month amount, and provides navigation to the relevant service, key, or breakdown section.
- [ ] Service contributions use the existing monthly service spend calculation; keys and breakdown items use their available current-month costs. Missing costs remain unavailable, estimates retain the ≈ marker, and tagging never changes underlying spend.
- [ ] Within a tag and service, a tagged service contributes once and covers all other tagged targets. Without a service assignment, sum targets only when their costs are provably disjoint; otherwise show individual amounts and mark the combined total unavailable. For example, a $100 service and its $30 key tagged together contribute $100.

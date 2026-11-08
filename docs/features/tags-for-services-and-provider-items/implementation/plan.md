---
type: plan
feature: tags-for-services-and-provider-items
title: Tags for Services and Provider Items
issues:
  - id: I-1
    title: Generalize tag persistence and migrate existing key assignments
    summary: Introduce refresh-independent tag assignments for services, keys, and existing provider breakdown items. Scope identity by tracked service and target type; use provider IDs where available and dimension plus exact label otherwise, excluding month. Migrate existing key tags without loss, retain assignments for temporarily missing targets across restarts and month changes, treat renamed label-only items as new targets, and delete assignments when their service is removed. Verify migration, identity isolation, refresh retention, and service deletion.
    requirements: [AC-003, AC-004, AC-005, REQ-013]
    decisions: [DEC-024]
  - id: I-2
    title: Add shared tag editing to services and provider breakdown items
    summary: Provide tag editing for tracked services, including manual services, existing keys, and every displayed provider breakdown item. Share suggestions across target types; trim whitespace, ignore empty entries, and deduplicate case-insensitively. Keep assignments independent so service tags do not propagate to children. Preserve existing key editing and keep tags local without adding provider discovery or synchronization.
    requirements: [AC-001, AC-002, REQ-013, REQ-015, REQ-016]
    decisions: [DEC-024, DEC-027]
  - id: I-3
    title: Resolve current-month amounts for every tagged target type
    summary: Resolve tagged targets against current-month data using the existing monthly service spend calculation and available key or breakdown costs. Preserve unavailable states and estimate markers, retain missing targets as unavailable, and never reuse their previous spend as current-month spend. Include tagged services regardless of their inclusion in the main spending total, without changing underlying spend or introducing historical tag reporting. Verify month changes, missing costs, estimates, and temporarily absent targets.
    requirements: [AC-005, AC-007, REQ-013]
    decisions: [DEC-024]
  - id: I-4
    title: Prevent double counting in generalized tag totals
    summary: "Implement aggregation per tag and service: a tagged service contributes once and covers its tagged children; otherwise sum targets only when available data proves their costs are disjoint. Define the evidence used to establish disjointness and conservatively mark the combined total unavailable when overlap cannot be resolved, while retaining individual amounts. Preserve estimate status and allow financial overlap between different tags. Verify the $100 service plus $30 key example, disjoint targets, overlapping breakdown dimensions, and unresolved totals across services."
    requirements: [AC-007, AC-008, REQ-013]
    decisions: [DEC-024, DEC-027]
  - id: I-5
    title: Display generalized tag membership, totals, and navigation
    summary: Extend the Tags view to list each tagged target with its type, parent service, and current-month amount or unavailable state, preserving estimate markers. Display overlap-aware combined totals and make unresolved totals understandable alongside individual amounts. Provide navigation to the relevant service, key, or breakdown section, including a useful parent-service destination for temporarily missing targets. Verify navigation and presentation for mixed target types, missing targets, and unavailable combined totals.
    requirements: [AC-005, AC-006, AC-007, AC-008, REQ-013, REQ-015, REQ-016]
    decisions: [DEC-024, DEC-027]
updated: 2026-11-08
---

# Implementation plan — Tags for Services and Provider Items

## I-1: Generalize tag persistence and migrate existing key assignments

Introduce refresh-independent tag assignments for services, keys, and existing provider breakdown items. Scope identity by tracked service and target type; use provider IDs where available and dimension plus exact label otherwise, excluding month. Migrate existing key tags without loss, retain assignments for temporarily missing targets across restarts and month changes, treat renamed label-only items as new targets, and delete assignments when their service is removed. Verify migration, identity isolation, refresh retention, and service deletion.

Requirements: AC-003, AC-004, AC-005, REQ-013
Decisions: DEC-024

## I-2: Add shared tag editing to services and provider breakdown items

Provide tag editing for tracked services, including manual services, existing keys, and every displayed provider breakdown item. Share suggestions across target types; trim whitespace, ignore empty entries, and deduplicate case-insensitively. Keep assignments independent so service tags do not propagate to children. Preserve existing key editing and keep tags local without adding provider discovery or synchronization.

Requirements: AC-001, AC-002, REQ-013, REQ-015, REQ-016
Decisions: DEC-024, DEC-027

## I-3: Resolve current-month amounts for every tagged target type

Resolve tagged targets against current-month data using the existing monthly service spend calculation and available key or breakdown costs. Preserve unavailable states and estimate markers, retain missing targets as unavailable, and never reuse their previous spend as current-month spend. Include tagged services regardless of their inclusion in the main spending total, without changing underlying spend or introducing historical tag reporting. Verify month changes, missing costs, estimates, and temporarily absent targets.

Requirements: AC-005, AC-007, REQ-013
Decisions: DEC-024

## I-4: Prevent double counting in generalized tag totals

Implement aggregation per tag and service: a tagged service contributes once and covers its tagged children; otherwise sum targets only when available data proves their costs are disjoint. Define the evidence used to establish disjointness and conservatively mark the combined total unavailable when overlap cannot be resolved, while retaining individual amounts. Preserve estimate status and allow financial overlap between different tags. Verify the $100 service plus $30 key example, disjoint targets, overlapping breakdown dimensions, and unresolved totals across services.

Requirements: AC-007, AC-008, REQ-013
Decisions: DEC-024, DEC-027

## I-5: Display generalized tag membership, totals, and navigation

Extend the Tags view to list each tagged target with its type, parent service, and current-month amount or unavailable state, preserving estimate markers. Display overlap-aware combined totals and make unresolved totals understandable alongside individual amounts. Provide navigation to the relevant service, key, or breakdown section, including a useful parent-service destination for temporarily missing targets. Verify navigation and presentation for mixed target types, missing targets, and unavailable combined totals.

Requirements: AC-005, AC-006, AC-007, AC-008, REQ-013, REQ-015, REQ-016
Decisions: DEC-024, DEC-027

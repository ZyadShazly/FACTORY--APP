# Production Execution & Quality Sprint

## Goal
Complete the production-floor workflow so a worker and supervisor can record who performed each operation, actual time, stoppages, output, rejection, and quality evidence without weakening the protected Production → Inventory → Actual Cost boundary.

## In scope
- assign operations to an employee or production team
- record start, pause, resume, and completion timestamps
- require stoppage reasons and preserve stoppage history
- record actual minutes, accepted quantity, rejected quantity, and rework quantity
- quality-check decision with supervisor identity, notes, and optional evidence references
- role-aware production-floor UI optimized for simple daily use
- protected RPC-only mutations and immutable execution history
- reporting hooks for planned-versus-actual time and rejection rates

## Safety boundaries
- additive schema and versioned workflow changes only
- no rewrite or deletion of existing production orders, material issues, inventory movements, or Actual Cost entries
- no automatic production return, waste, or damage posting until quantity and Actual Cost treatment are reviewed together
- no direct client writes to protected production tables
- no completion when accepted/rejected/rework quantities are inconsistent
- no merge until migration review/application, live permissions review, rollback-safe smoke tests, repository tests/build, Vercel checks, and full Project → Procurement → Inventory → Production → Actual Cost regression pass

## Initial review questions
1. Which existing employee and profile identifiers should be canonical for operation assignment?
2. Can a single operation be worked by multiple employees, or should the first release support one responsible employee plus notes?
3. How should rejected and rework quantities affect finished output and cost?
4. Which evidence storage path and access policy should be reused for quality attachments?

The implementation must prefer the smallest safe model that preserves history and can be extended later without destructive conversion.

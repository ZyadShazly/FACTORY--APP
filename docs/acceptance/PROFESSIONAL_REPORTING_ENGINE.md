# Professional Reporting Engine Acceptance

- Exports are decision-ready reports, not raw table dumps.
- Payroll export includes summary, employee totals, deductions with reasons, advances, bonuses, approval state, and audit metadata.
- External labor export includes workers, projects, hours, overtime, rates, approvals, payment references, and totals.
- Inventory export includes summary, stock balances, movements, below-zero/exception checks, and warehouse context.
- Every workbook includes company/report title, generated timestamp, generated-by user, active filters, frozen headers, filters, widths, totals, and currency/date formatting.
- PDF/print output preserves the same review context as the workbook.
- Sensitive financial data remains permission-aware.
- No export may require the reviewer to reopen the system to understand the decision being requested.
- Any database migration must be additive, reviewed before application, and followed by live permission review and rollback-safe smoke tests.
- Full tests/build, Vercel checks, clean-tree verification, and cross-module regression are required before merge.

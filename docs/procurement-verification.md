# Procurement verification checklist

- Migration reviewed against live prerequisite tables and UUID keys.
- Migration applied to the FACTORY APP Supabase project.
- All procurement tables verified with RLS enabled.
- Direct `anon` and `authenticated` table privileges remain revoked.
- Rollback-safe smoke test covers request, order, receipt, and invoice boundaries.
- Security and performance advisors are reviewed after deployment.
- Repository and Vercel checks must pass before merge.

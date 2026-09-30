-- Accounting verification hardening: internal helper ACLs only.
-- These private helpers are invoked by accounting triggers / protected RPCs.
-- They must not be directly executable by API roles.

revoke all on function private.accounting_assert_entry_balanced(uuid)
  from public, anon, authenticated;

revoke all on function private.accounting_deferred_balance_guard()
  from public, anon, authenticated;

revoke all on function private.accounting_guard_account_hierarchy()
  from public, anon, authenticated;

revoke all on function private.accounting_guard_account_state()
  from public, anon, authenticated;

revoke all on function private.accounting_guard_period_overlap()
  from public, anon, authenticated;

revoke all on function private.accounting_guard_posting_account()
  from public, anon, authenticated;

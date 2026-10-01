-- Fix deferred journal balance validation after internal helper ACL hardening.
-- The deferred constraint trigger fires at transaction end, after SECURITY DEFINER
-- journal RPCs return, so it must retain a trusted execution context while calling
-- private.accounting_assert_entry_balanced().

alter function private.accounting_deferred_balance_guard()
  security definer;

-- Keep the trigger helper internal-only. Trigger execution does not require
-- direct API-role EXECUTE privileges.
revoke all on function private.accounting_deferred_balance_guard()
  from public, anon, authenticated;

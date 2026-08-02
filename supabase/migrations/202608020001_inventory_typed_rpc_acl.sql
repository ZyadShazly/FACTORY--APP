-- Restrict typed inventory item creation to authenticated users.
-- The function keeps its internal owner/manager authorization check.
begin;

revoke execute on function
  public.create_inventory_item_typed(text,text,text,text,uuid,boolean)
from public, anon;

grant execute on function
  public.create_inventory_item_typed(text,text,text,text,uuid,boolean)
to authenticated;

commit;

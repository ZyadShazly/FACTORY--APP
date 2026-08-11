import { useCallback, useEffect, useState } from "react";
import { supabase } from "../supabaseClient";

export function useInventoryWorkspace(channelScope = "workspace") {
  const [workspace, setWorkspace] = useState(null);
  const [error, setError] = useState("");
  const [updatedAt, setUpdatedAt] = useState(null);

  const reload = useCallback(async () => {
    const result = await supabase.rpc("get_inventory_workspace");
    if (result.error) {
      setError("تعذر تحميل رصيد دفتر المخزون؛ لم يتم عرض تقدير بديل.");
      return result;
    }
    setWorkspace(result.data || {});
    setError("");
    setUpdatedAt(new Date());
    return result;
  }, []);

  useEffect(() => {
    let active = true;
    const load = async () => {
      const result = await supabase.rpc("get_inventory_workspace");
      if (!active) return result;
      if (result.error) setError("تعذر تحميل رصيد دفتر المخزون؛ لم يتم عرض تقدير بديل.");
      else { setWorkspace(result.data || {}); setError(""); setUpdatedAt(new Date()); }
      return result;
    };
    void load();
    const channel = supabase.channel(`${channelScope}-inventory-ledger`)
      .on("postgres_changes", { event: "*", schema: "public", table: "inventory_movements" }, load)
      .subscribe();
    return () => { active = false; void supabase.removeChannel(channel); };
  }, [channelScope]);

  return { workspace, error, updatedAt, reload };
}

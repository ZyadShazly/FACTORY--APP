export const EMPTY_DATA = Object.freeze({
  materials: [], materialPurchases: [], products: [], productionOrders: [],
  sales: [], rentals: [], suppliers: [], supplierPayments: [], customers: [], customerReceipts: [], expenses: [],
  profiles: [], projects: [], projectFiles: [], projectActivities: [], projectMilestones: [], projectMembers: [], projectRealtimeSignal: [], employees: [], payroll: [], dailyLabor: [], projectCosts: [], auditLog: [],
  departments: [], workSchedules: [], workScheduleDays: [], holidayCalendar: [], holidayScopes: [],
  assetCategories: [], assetLocations: [], assets: [], assetAssignments: [], assetAssignmentItems: [], assetReturnEvents: [], assetReturnItems: [], assetSettlements: [], assetMovements: [], assetAttachments: [], assetAlerts: [],
});

function tableLabel(pageLabels, key, table) {
  return pageLabels?.[key] || table;
}

export function createTableFetcher({
  supabase,
  withTimeout,
  projectFilesTable,
  pageLabels = {},
  logger = console,
}) {
  if (!supabase) throw new Error("supabase client is required");
  if (typeof withTimeout !== "function") throw new Error("withTimeout is required");
  if (!projectFilesTable) throw new Error("projectFilesTable is required");

  return async function fetchTableRows(key, table) {
    let fetchResult;
    try {
      const timeoutLabel = `انتهت مهلة تحميل ${tableLabel(pageLabels, key, table)}`;

      if (key === "projects") {
        fetchResult = await withTimeout(supabase.rpc("get_projects_visible"), undefined, timeoutLabel);
      } else if (key === "productionOrders") {
        fetchResult = await withTimeout(supabase.rpc("get_production_orders_visible"), undefined, timeoutLabel);
      } else if (key === "assets") {
        fetchResult = await withTimeout(supabase.rpc("get_assets_visible"), undefined, timeoutLabel);
      } else if (key === "payroll") {
        fetchResult = await withTimeout(supabase.rpc("get_payroll_visible"), undefined, timeoutLabel);
      } else if (key === "assetAlerts") {
        fetchResult = await withTimeout(
          supabase.rpc("get_asset_alerts_visible"),
          undefined,
          "انتهت مهلة تحميل تنبيهات الأصول",
        );
      } else if (key === "auditLog") {
        fetchResult = await withTimeout(
          supabase
            .from(table)
            .select("*, actor:profiles!audit_log_actor_id_fkey(full_name,email)")
            .order("created_at", { ascending: true }),
          undefined,
          timeoutLabel,
        );

        if (fetchResult.error) {
          logger.warn?.("[AuditLog] actor profile relation unavailable; using legacy rows", fetchResult.error);
          fetchResult = await withTimeout(
            supabase.from(table).select("*").order("created_at", { ascending: true }),
          );
        }
      } else {
        fetchResult = await withTimeout(
          supabase.from(table).select("*").order("created_at", { ascending: true }),
          undefined,
          timeoutLabel,
        );

        if (key === "projectFiles" && fetchResult.error?.code === "42703") {
          logger.warn?.("[ProjectFiles] created_at is missing; falling back to uploaded_at", fetchResult.error);
          fetchResult = await withTimeout(
            supabase.from(projectFilesTable).select("*").order("uploaded_at", { ascending: true }),
          );
        }
      }
    } catch (error) {
      fetchResult = { data: null, error };
    }

    if (key === "projectFiles") {
      logger.info?.("[ProjectFiles] fetchResult", { table: projectFilesTable, fetchResult });
    }
    if (fetchResult?.error) {
      logger.error?.(`[NEXTEP] Failed to fetch ${table}`, fetchResult.error);
    }
    return fetchResult;
  };
}

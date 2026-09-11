const active = (row) => (row.status || "posted") !== "reversed";
const legacy = (row) => !row.transaction_classification;

function settledAmount(row) {
  if (!active(row)) return 0;
  if (legacy(row)) return Number(row.amount || 0);
  return Number(row.settlement_amount || 0) + Number(row.allocated_advance_amount || 0);
}

function availableAdvance(row) {
  if (!active(row) || legacy(row)) return 0;
  return Math.max(0, Number(row.advance_amount || 0) - Number(row.allocated_advance_amount || 0));
}

export function customerBalances(customerId, data) {
  const charges = (data.sales || []).filter((row) => row.customer_id === customerId && row.status !== "cancelled").reduce((sum, row) => sum + Number(row.total || 0), 0)
    + (data.rentals || []).filter((row) => row.customer_id === customerId && row.status !== "cancelled").reduce((sum, row) => sum + Number(row.rental_fee || 0), 0)
    + (data.projects || []).filter((row) => row.customer_id === customerId && row.lifecycle === "closed").reduce((sum, row) => sum + Number(row.revenue || 0), 0);
  const rows = (data.customerReceipts || []).filter((row) => row.customer_id === customerId);
  const settled = rows.reduce((sum, row) => sum + settledAmount(row), 0);
  return {
    due: Math.max(0, charges - settled),
    advance: rows.reduce((sum, row) => sum + availableAdvance(row), 0),
    cashReceived: rows.filter(active).reduce((sum, row) => sum + Number(row.amount || 0), 0),
    legacyUnclassified: rows.filter((row) => active(row) && legacy(row)).length,
  };
}

export function supplierBalances(supplierId, data) {
  const charges = (data.materialPurchases || []).filter((row) => row.supplier_id === supplierId).reduce((sum, row) => sum + Number(row.qty || 0) * Number(row.unit_cost || 0), 0)
    + (data.supplierInvoices || []).filter((row) => row.supplier_id === supplierId && ["approved", "paid"].includes(row.status)).reduce((sum, row) => sum + Number(row.total_amount || 0), 0);
  const rows = (data.supplierPayments || []).filter((row) => row.supplier_id === supplierId);
  const settled = rows.reduce((sum, row) => sum + settledAmount(row), 0);
  return {
    due: Math.max(0, charges - settled),
    advance: rows.reduce((sum, row) => sum + availableAdvance(row), 0),
    cashPaid: rows.filter(active).reduce((sum, row) => sum + Number(row.amount || 0), 0),
    legacyUnclassified: rows.filter((row) => active(row) && legacy(row)).length,
  };
}

export function transactionClassLabel(row) {
  if ((row.status || "posted") === "reversed") return "معكوسة";
  return ({ settlement: "تسوية مستحق", advance: "سلفة", mixed: "تسوية + سلفة" })[row.transaction_classification] || "حركة قديمة غير مصنفة";
}

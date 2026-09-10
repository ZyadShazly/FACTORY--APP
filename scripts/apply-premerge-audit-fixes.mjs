import fs from "node:fs";

function replaceExact(path, before, after) {
  const source = fs.readFileSync(path, "utf8");
  if (source.includes(after)) return false;
  if (!source.includes(before)) throw new Error(`Patch anchor missing in ${path}: ${before.slice(0,120)}`);
  fs.writeFileSync(path, source.replace(before, after));
  return true;
}

let changed = false;

changed = replaceExact(
  "src/AppMonolith.jsx",
  `function customerRentalTotal(customerId, data) {\n  return data.rentals.filter((r) => r.customer_id === customerId && r.status !== "cancelled").reduce((s, r) => s + r.rental_fee, 0);\n}\nfunction customerBalance(customerId, data) { return customerBalances(customerId, data).due; }`,
  `function customerRentalTotal(customerId, data) {\n  return data.rentals.filter((r) => r.customer_id === customerId && r.status !== "cancelled").reduce((s, r) => s + r.rental_fee, 0);\n}\nfunction customerProjectTotal(customerId, data) {\n  return (data.projects || []).filter((p) => p.customer_id === customerId && p.lifecycle === "closed").reduce((s, p) => s + num(p.revenue), 0);\n}\nfunction customerBalance(customerId, data) { return customerBalances(customerId, data).due; }`
) || changed;

changed = replaceExact(
  "src/AppMonolith.jsx",
  `<Table headers={["العميل", "الهاتف", "إجمالي المبيعات والإيجارات", "إجمالي التحصيل", "المستحق", "السلفة", ""]}>`,
  `<Table headers={["العميل", "الهاتف", "إجمالي المستحقات", "إجمالي التحصيل", "المستحق", "السلفة", ""]}>`
) || changed;

changed = replaceExact(
  "src/AppMonolith.jsx",
  `<Td>{c.name}</Td><Td>{c.phone || "—"}</Td><Td>{formatMoney(customerSaleTotal(c.id, data) + customerRentalTotal(c.id, data))}</Td><Td>{formatMoney(customerReceiptTotal(c.id, data))}</Td>`,
  `<Td>{c.name}</Td><Td>{c.phone || "—"}</Td><Td>{formatMoney(customerSaleTotal(c.id, data) + customerRentalTotal(c.id, data) + customerProjectTotal(c.id, data))}</Td><Td>{formatMoney(customerReceiptTotal(c.id, data))}</Td>`
) || changed;

changed = replaceExact(
  "src/AppMonolith.jsx",
  `function CustomerLedger({ customerId, data }) {\n  const sales = data.sales.filter((s) => s.customer_id === customerId).map((s) => ({ date: s.sale_date, type: s.status === "cancelled" ? "بيع ملغي" : "بيع", amount: s.status === "cancelled" ? 0 : s.total, note: \`${'${data.products.find((p) => p.id === s.product_id)?.name || "—"}${s.status === "cancelled" ? ` — ${s.cancellation_reason || "ملغي"}` : ""}'}\` }));\n  const rentals = data.rentals.filter((r) => r.customer_id === customerId).map((r) => ({ date: r.start_date, type: r.status === "cancelled" ? "إيجار ملغي" : "إيجار", amount: r.status === "cancelled" ? 0 : r.rental_fee, note: \`${'${data.products.find((p) => p.id === r.product_id)?.name || "—"}${r.status === "cancelled" ? ` — ${r.cancellation_reason || "ملغي"}` : ""}'}\` }));\n  const receipts = data.customerReceipts.filter((r) => r.customer_id === customerId).map((r) => ({ date: r.receipt_date, type: transactionClassLabel(r), amount: -r.amount, note: r.note }));\n  const rows = [...sales, ...rentals, ...receipts].sort((a, b) => (a.date || "").localeCompare(b.date || ""));`,
  `function CustomerLedger({ customerId, data }) {\n  const sales = data.sales.filter((s) => s.customer_id === customerId).map((s) => ({ date: s.sale_date, type: s.status === "cancelled" ? "بيع ملغي" : "بيع", amount: s.status === "cancelled" ? 0 : s.total, note: \`${'${data.products.find((p) => p.id === s.product_id)?.name || "—"}${s.status === "cancelled" ? ` — ${s.cancellation_reason || "ملغي"}` : ""}'}\` }));\n  const rentals = data.rentals.filter((r) => r.customer_id === customerId).map((r) => ({ date: r.start_date, type: r.status === "cancelled" ? "إيجار ملغي" : "إيجار", amount: r.status === "cancelled" ? 0 : r.rental_fee, note: \`${'${data.products.find((p) => p.id === r.product_id)?.name || "—"}${r.status === "cancelled" ? ` — ${r.cancellation_reason || "ملغي"}` : ""}'}\` }));\n  const projects = (data.projects || []).filter((p) => p.customer_id === customerId && p.lifecycle === "closed" && num(p.revenue) > 0).map((p) => ({ date: String(p.project_closed_at || p.lifecycle_changed_at || p.delivery_date || p.updated_at || "").slice(0,10), type: "إقفال مشروع", amount: num(p.revenue), note: \`${'${p.project_code || "مشروع"} · ${p.project_name || "—"}'}\` }));\n  const receipts = data.customerReceipts.filter((r) => r.customer_id === customerId).map((r) => ({ date: r.receipt_date, type: transactionClassLabel(r), amount: r.status === "reversed" ? 0 : -r.amount, note: r.reversal_reason ? \`${'${r.note || ""}${r.note ? " · " : ""}سبب العكس: ${r.reversal_reason}'}\` : r.note }));\n  const rows = [...sales, ...rentals, ...projects, ...receipts].sort((a, b) => (a.date || "").localeCompare(b.date || ""));`
) || changed;

changed = replaceExact(
  "src/AppMonolith.jsx",
  `const payments = data.supplierPayments.filter((p) => p.supplier_id === supplierId).map((p) => ({ date: p.payment_date, type: transactionClassLabel(p), amount: -p.amount, note: p.note }));`,
  `const payments = data.supplierPayments.filter((p) => p.supplier_id === supplierId).map((p) => ({ date: p.payment_date, type: transactionClassLabel(p), amount: p.status === "reversed" ? 0 : -p.amount, note: p.reversal_reason ? \`${'${p.note || ""}${p.note ? " · " : ""}سبب العكس: ${p.reversal_reason}'}\` : p.note }));`
) || changed;

console.log(changed ? "Pre-merge audit UI fixes applied." : "Pre-merge audit UI fixes already applied.");

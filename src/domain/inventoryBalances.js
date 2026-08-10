export function aggregateInventoryByMaterial(workspace = {}) {
  const items = Array.isArray(workspace.items) ? workspace.items : [];
  const balances = Array.isArray(workspace.balances) ? workspace.balances : [];
  const byItem = new Map(items.map((item) => [item.id, item]));
  const result = new Map();

  for (const row of balances) {
    const item = byItem.get(row.inventory_item_id);
    if (!item?.material_id) continue;
    const current = result.get(item.material_id) || {
      materialId: item.material_id,
      inventoryItemId: item.id,
      itemName: item.name,
      unit: item.unit || row.unit || "وحدة",
      quantityOnHand: 0,
      warehouseNames: new Set(),
    };
    current.quantityOnHand += Number(row.quantity_on_hand || 0);
    if (row.warehouse_name) current.warehouseNames.add(row.warehouse_name);
    result.set(item.material_id, current);
  }

  return new Map([...result].map(([materialId, row]) => [materialId, {
    ...row,
    warehouseNames: [...row.warehouseNames].sort(),
  }]));
}

export function canonicalMaterialAlerts(workspace = {}, threshold = 10) {
  const aggregate = aggregateInventoryByMaterial(workspace);
  const materials = Array.isArray(workspace.materials) ? workspace.materials : [];
  const unlinkedIds = new Set((workspace.unlinked_materials || []).map((row) => row.id));
  return {
    low: materials
      .filter((material) => !unlinkedIds.has(material.id) && aggregate.has(material.id))
      .map((material) => ({ ...material, ...aggregate.get(material.id) }))
      .filter((material) => material.quantityOnHand <= threshold)
      .sort((a, b) => a.quantityOnHand - b.quantityOnHand),
    unlinked: materials.filter((material) => unlinkedIds.has(material.id)),
  };
}

export function aggregateInventoryByProduct(workspace = {}) {
  const items = Array.isArray(workspace.items) ? workspace.items : [];
  const balances = Array.isArray(workspace.balances) ? workspace.balances : [];
  const byItem = new Map(items.map((item) => [item.id, item]));
  const result = new Map();

  for (const row of balances) {
    const item = byItem.get(row.inventory_item_id);
    if (!item?.product_id || item.item_type !== "finished_good") continue;
    const current = result.get(item.product_id) || {
      productId: item.product_id,
      inventoryItemId: item.id,
      itemName: item.name,
      unit: item.unit || row.unit || "وحدة",
      quantityOnHand: 0,
      inventoryValue: 0,
      warehouseNames: new Set(),
    };
    current.quantityOnHand += Number(row.quantity_on_hand || 0);
    current.inventoryValue += Number(row.inventory_value || 0);
    if (row.warehouse_name) current.warehouseNames.add(row.warehouse_name);
    result.set(item.product_id, current);
  }

  return new Map([...result].map(([productId, row]) => [productId, {
    ...row,
    warehouseNames: [...row.warehouseNames].sort(),
  }]));
}

export function canonicalFinishedProductAlerts(workspace = {}, products = [], threshold = 5) {
  const aggregate = aggregateInventoryByProduct(workspace);
  const activeProducts = products.filter((product) => !product.archived_at);
  return {
    low: activeProducts
      .filter((product) => aggregate.has(product.id))
      .map((product) => ({ ...product, ...aggregate.get(product.id) }))
      .filter((product) => product.quantityOnHand <= threshold)
      .sort((a, b) => a.quantityOnHand - b.quantityOnHand),
    unlinked: activeProducts.filter((product) => !aggregate.has(product.id)),
  };
}

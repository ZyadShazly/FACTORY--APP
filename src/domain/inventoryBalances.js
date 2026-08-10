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

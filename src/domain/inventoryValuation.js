const MONEY_SCALE = 100;
const COST_SCALE = 10000;

const roundTo = (value, scale) => Math.round((value + Number.EPSILON) * scale) / scale;

function positive(value, label, allowZero = false) {
  const number = Number(value);
  if (!Number.isFinite(number) || (allowZero ? number < 0 : number <= 0)) {
    throw new Error(`${label} must be ${allowZero ? "non-negative" : "greater than zero"}`);
  }
  return number;
}

export function calculateMovingWeightedAverageReceipt({
  currentQuantity,
  currentValue,
  receiptQuantity,
  receiptUnitCost,
}) {
  const quantity = positive(currentQuantity, "currentQuantity", true);
  const value = positive(currentValue, "currentValue", true);
  const incomingQuantity = positive(receiptQuantity, "receiptQuantity");
  const incomingUnitCost = positive(receiptUnitCost, "receiptUnitCost", true);
  const nextQuantity = quantity + incomingQuantity;
  const nextValue = roundTo(value + incomingQuantity * incomingUnitCost, MONEY_SCALE);
  return {
    quantityOnHand: roundTo(nextQuantity, COST_SCALE),
    inventoryValue: nextValue,
    averageUnitCost: roundTo(nextValue / nextQuantity, COST_SCALE),
  };
}

export function calculateMovingWeightedAverageIssue({
  currentQuantity,
  currentValue,
  issueQuantity,
}) {
  const quantity = positive(currentQuantity, "currentQuantity");
  const value = positive(currentValue, "currentValue", true);
  const issued = positive(issueQuantity, "issueQuantity");
  if (issued - quantity > 0.0001) throw new Error("Insufficient inventory quantity");
  const averageUnitCost = roundTo(value / quantity, COST_SCALE);
  const issueValue = roundTo(averageUnitCost * issued, MONEY_SCALE);
  return {
    unitCost: averageUnitCost,
    issueValue,
    quantityOnHand: roundTo(quantity - issued, COST_SCALE),
    inventoryValue: roundTo(Math.max(0, value - issueValue), MONEY_SCALE),
  };
}

export function calculateFifoIssue({ layers, issueQuantity }) {
  const requested = positive(issueQuantity, "issueQuantity");
  if (!Array.isArray(layers)) throw new Error("layers must be an array");
  const ordered = layers
    .map((layer) => ({
      ...layer,
      remainingQuantity: positive(layer.remainingQuantity, "layer.remainingQuantity", true),
      unitCost: positive(layer.unitCost, "layer.unitCost", true),
    }))
    .filter((layer) => layer.remainingQuantity > 0)
    .sort((a, b) => {
      const dateOrder = String(a.receivedAt || "").localeCompare(String(b.receivedAt || ""));
      return dateOrder || String(a.id || "").localeCompare(String(b.id || ""));
    });

  const available = ordered.reduce((sum, layer) => sum + layer.remainingQuantity, 0);
  if (requested - available > 0.0001) throw new Error("Insufficient FIFO layer quantity");

  let remainingToIssue = requested;
  let issueValue = 0;
  const consumptions = [];
  const updatedLayers = ordered.map((layer) => {
    const consumed = Math.min(layer.remainingQuantity, remainingToIssue);
    remainingToIssue = roundTo(remainingToIssue - consumed, COST_SCALE);
    issueValue += consumed * layer.unitCost;
    if (consumed > 0) {
      consumptions.push({
        layerId: layer.id,
        quantity: consumed,
        unitCost: layer.unitCost,
        amount: roundTo(consumed * layer.unitCost, MONEY_SCALE),
      });
    }
    return {
      ...layer,
      remainingQuantity: roundTo(layer.remainingQuantity - consumed, COST_SCALE),
    };
  });

  const roundedValue = roundTo(issueValue, MONEY_SCALE);
  return {
    issueQuantity: requested,
    issueValue: roundedValue,
    unitCost: roundTo(roundedValue / requested, COST_SCALE),
    consumptions,
    remainingLayers: updatedLayers.filter((layer) => layer.remainingQuantity > 0),
  };
}

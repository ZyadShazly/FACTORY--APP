import test from "node:test";
import assert from "node:assert/strict";
import {
  calculateFifoIssue,
  calculateMovingWeightedAverageIssue,
  calculateMovingWeightedAverageReceipt,
} from "../src/domain/inventoryValuation.js";

test("moving weighted average receipt recalculates the average cost", () => {
  const result = calculateMovingWeightedAverageReceipt({
    currentQuantity: 10, currentValue: 1000, receiptQuantity: 10, receiptUnitCost: 140,
  });
  assert.equal(result.quantityOnHand, 20);
  assert.equal(result.inventoryValue, 2400);
  assert.equal(result.averageUnitCost, 120);
});

test("moving weighted average issue uses the current average and preserves balance", () => {
  const result = calculateMovingWeightedAverageIssue({
    currentQuantity: 20, currentValue: 2400, issueQuantity: 5,
  });
  assert.equal(result.unitCost, 120);
  assert.equal(result.issueValue, 600);
  assert.equal(result.quantityOnHand, 15);
  assert.equal(result.inventoryValue, 1800);
});

test("FIFO consumes the oldest layer first and then the next layer", () => {
  const result = calculateFifoIssue({
    issueQuantity: 7,
    layers: [
      { id: "new", receivedAt: "2026-02-01", remainingQuantity: 8, unitCost: 150 },
      { id: "old", receivedAt: "2026-01-01", remainingQuantity: 5, unitCost: 100 },
    ],
  });
  assert.deepEqual(result.consumptions, [
    { layerId: "old", quantity: 5, unitCost: 100, amount: 500 },
    { layerId: "new", quantity: 2, unitCost: 150, amount: 300 },
  ]);
  assert.equal(result.issueValue, 800);
  assert.deepEqual(result.remainingLayers.map((layer) => [layer.id, layer.remainingQuantity]), [["new", 6]]);
});

test("FIFO rejects an issue larger than the remaining layer quantity", () => {
  assert.throws(() => calculateFifoIssue({
    issueQuantity: 6,
    layers: [{ id: "only", receivedAt: "2026-01-01", remainingQuantity: 5, unitCost: 10 }],
  }), /Insufficient FIFO/);
});

test("moving weighted average rejects negative stock", () => {
  assert.throws(() => calculateMovingWeightedAverageIssue({
    currentQuantity: 3, currentValue: 30, issueQuantity: 4,
  }), /Insufficient inventory/);
});

import test from "node:test";
import assert from "node:assert/strict";
import { calculateProjectCostAllocations } from "../src/domain/projectCostAllocation.js";

test("fixed amounts allocate the full source amount", () => {
  const result = calculateProjectCostAllocations({
    sourceAmount: 1000,
    method: "fixed_amount",
    allocations: [
      { projectId: "p1", allocationValue: 600 },
      { projectId: "p2", allocationValue: 400 },
    ],
  });
  assert.deepEqual(result.allocations.map((row) => row.allocatedAmount), [600, 400]);
  assert.equal(result.unallocatedAmount, 0);
});

test("percentage allocation reconciles rounding to the final project", () => {
  const result = calculateProjectCostAllocations({
    sourceAmount: 100,
    method: "percentage",
    allocations: [
      { projectId: "p1", allocationValue: 33.3333 },
      { projectId: "p2", allocationValue: 33.3333 },
      { projectId: "p3", allocationValue: 33.3334 },
    ],
  });
  assert.equal(result.allocatedAmount, 100);
  assert.equal(result.unallocatedAmount, 0);
});

test("quantity allocation splits purchase line value by allocated quantity", () => {
  const result = calculateProjectCostAllocations({
    sourceAmount: 1200,
    sourceQuantity: 12,
    method: "quantity",
    allocations: [
      { projectId: "p1", allocationValue: 5 },
      { projectId: "p2", allocationValue: 7 },
    ],
  });
  assert.deepEqual(result.allocations.map((row) => row.allocatedAmount), [500, 700]);
});

test("partial allocations report the unallocated source amount explicitly", () => {
  const result = calculateProjectCostAllocations({
    sourceAmount: 1000,
    method: "fixed_amount",
    requireFullAllocation: false,
    allocations: [{ projectId: "p1", allocationValue: 350 }],
  });
  assert.equal(result.allocatedAmount, 350);
  assert.equal(result.unallocatedAmount, 650);
});

test("rejects over-allocation and incomplete mandatory allocation", () => {
  assert.throws(() => calculateProjectCostAllocations({
    sourceAmount: 100,
    method: "percentage",
    allocations: [{ projectId: "p1", allocationValue: 80 }],
  }), /must total 100/);
  assert.throws(() => calculateProjectCostAllocations({
    sourceAmount: 100,
    method: "fixed_amount",
    allocations: [
      { projectId: "p1", allocationValue: 70 },
      { projectId: "p2", allocationValue: 50 },
    ],
  }), /exceed/);
});

test("rejects duplicate projects and invalid allocation values", () => {
  assert.throws(() => calculateProjectCostAllocations({
    sourceAmount: 100,
    method: "fixed_amount",
    allocations: [
      { projectId: "p1", allocationValue: 50 },
      { projectId: "p1", allocationValue: 50 },
    ],
  }), /Duplicate project/);
  assert.throws(() => calculateProjectCostAllocations({
    sourceAmount: 100,
    method: "fixed_amount",
    allocations: [{ projectId: "p1", allocationValue: -1 }],
  }), /non-negative/);
});

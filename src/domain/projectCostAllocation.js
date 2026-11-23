const MONEY_SCALE = 100;
const TOLERANCE = 0.01;

function finiteNonNegative(value, label) {
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0) {
    throw new Error(`${label} must be a finite non-negative number`);
  }
  return number;
}

function cents(value) {
  return Math.round((value + Number.EPSILON) * MONEY_SCALE) / MONEY_SCALE;
}

/**
 * Split a source cost across projects without losing cents to rounding.
 *
 * Supported methods:
 * - fixed_amount: allocation_value is an amount in the source currency.
 * - percentage: allocation_value is a percentage of sourceAmount.
 * - quantity: allocation_value is a quantity out of sourceQuantity.
 *
 * Partial allocation is opt-in. The returned unallocatedAmount is always
 * explicit so callers cannot silently treat a partial split as complete.
 */
export function calculateProjectCostAllocations({
  sourceAmount,
  allocations,
  method,
  sourceQuantity,
  requireFullAllocation = true,
}) {
  const total = finiteNonNegative(sourceAmount, "sourceAmount");
  if (total <= 0) throw new Error("sourceAmount must be greater than zero");
  if (!Array.isArray(allocations) || allocations.length === 0) {
    throw new Error("At least one project allocation is required");
  }
  if (!["fixed_amount", "percentage", "quantity"].includes(method)) {
    throw new Error("Unsupported allocation method");
  }

  const seenProjects = new Set();
  const normalized = allocations.map((row, index) => {
    const projectId = String(row?.projectId ?? "").trim();
    if (!projectId) throw new Error(`Project is required for allocation ${index + 1}`);
    if (seenProjects.has(projectId)) throw new Error(`Duplicate project allocation: ${projectId}`);
    seenProjects.add(projectId);
    return {
      projectId,
      value: finiteNonNegative(row?.allocationValue, `allocationValue[${index}]`),
    };
  });

  const denominator = method === "percentage"
    ? 100
    : method === "quantity"
      ? finiteNonNegative(sourceQuantity, "sourceQuantity")
      : total;

  if (denominator <= 0) {
    throw new Error(method === "quantity"
      ? "sourceQuantity must be greater than zero"
      : "Allocation denominator must be greater than zero");
  }

  const allocatedBasis = normalized.reduce((sum, row) => sum + row.value, 0);
  if (allocatedBasis - denominator > TOLERANCE) {
    throw new Error("Project allocations exceed the source amount or basis");
  }
  if (requireFullAllocation && Math.abs(allocatedBasis - denominator) > TOLERANCE) {
    throw new Error(method === "percentage"
      ? "Project allocation percentages must total 100%"
      : method === "quantity"
        ? "Allocated quantities must equal the source quantity"
        : "Fixed allocations must equal the source amount");
  }

  let allocatedAmount = 0;
  const result = normalized.map((row, index) => {
    const isLast = index === normalized.length - 1;
    const rawAmount = method === "fixed_amount"
      ? row.value
      : total * row.value / denominator;
    const amount = isLast && requireFullAllocation
      ? cents(total - allocatedAmount)
      : cents(rawAmount);
    allocatedAmount = cents(allocatedAmount + amount);
    return {
      projectId: row.projectId,
      allocationMethod: method,
      allocationValue: row.value,
      allocatedAmount: amount,
    };
  });

  if (allocatedAmount - total > TOLERANCE) {
    throw new Error("Rounded project allocations exceed the source amount");
  }
  if (requireFullAllocation && Math.abs(allocatedAmount - total) > TOLERANCE) {
    throw new Error("Rounded project allocations do not reconcile to the source amount");
  }

  return {
    allocations: result,
    allocatedAmount,
    unallocatedAmount: cents(total - allocatedAmount),
  };
}

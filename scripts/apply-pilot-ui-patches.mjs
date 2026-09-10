import fs from "node:fs";

function replaceExact(path, before, after) {
  const source = fs.readFileSync(path, "utf8");
  if (source.includes(after)) return false;
  if (!source.includes(before)) throw new Error(`Patch anchor missing in ${path}`);
  fs.writeFileSync(path, source.replace(before, after));
  return true;
}

let changed = false;

changed = replaceExact(
  "src/AppMonolith.jsx",
  "    const unitPrice = num(form.unitPrice) || selectedProduct.selling_price;\n    if (!Number.isFinite(unitPrice) || unitPrice <= 0) return setErr(\"سعر الوحدة يجب أن يكون أكبر من صفر\");",
  "    const unitPrice = form.unitPrice === \"\" ? Number(selectedProduct.selling_price) : num(form.unitPrice);\n    if (!Number.isFinite(unitPrice) || unitPrice <= 0) return setErr(\"سعر الوحدة يجب أن يكون أكبر من صفر\");"
) || changed;

console.log(changed ? "Pilot UI patches applied." : "Pilot UI patches already applied.");

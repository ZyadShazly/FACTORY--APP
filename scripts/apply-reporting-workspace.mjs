import fs from "node:fs";

const appPath = new URL("../src/App.jsx", import.meta.url);
let source = fs.readFileSync(appPath, "utf8");

const importLine = 'import { ReportingWorkspace } from "./reporting/ReportingWorkspace";';
if (!source.includes(importLine)) {
  const anchor = 'import { AssetExternalConfirmation, AssetsPage } from "./assets/AssetsPage";';
  if (!source.includes(anchor)) throw new Error("Reporting patch anchor import was not found");
  source = source.replace(anchor, `${anchor}\n${importLine}`);
}

const startMarker = "/* ---------------------------------- Reports --------------------------------- */";
const endMarker = "/* ----------------------------------- Team ------------------------------------ */";
const start = source.indexOf(startMarker);
const end = source.indexOf(endMarker);
if (start < 0 || end < 0 || end <= start) throw new Error("Reporting patch boundaries were not found");

const replacement = `${startMarker}\nfunction ReportsTab() {\n  return <ReportingWorkspace />;\n}\n\n`;
source = source.slice(0, start) + replacement + source.slice(end);
fs.writeFileSync(appPath, source);
console.log("Protected reporting workspace is wired.");

const XML_NS = `xmlns="urn:schemas-microsoft-com:office:spreadsheet" xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:x="urn:schemas-microsoft-com:office:excel" xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet"`;

function esc(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

function safeSheetName(name) {
  return String(name || "Sheet").replace(/[\\/?*\[\]:]/g, " ").slice(0, 31);
}

function valueType(value, type) {
  if (type === "number" || typeof value === "number") return "Number";
  if (type === "date" && value) return "DateTime";
  return "String";
}

function normalizeDate(value) {
  if (!value) return "";
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? "" : date.toISOString();
}

function cell(value, { style = "Text", type } = {}) {
  const resolvedType = valueType(value, type);
  const content = resolvedType === "DateTime" ? normalizeDate(value) : value ?? "";
  return `<Cell ss:StyleID="${style}"><Data ss:Type="${resolvedType}">${esc(content)}</Data></Cell>`;
}

function row(cells, height) {
  return `<Row${height ? ` ss:Height="${height}"` : ""}>${cells.join("")}</Row>`;
}

function metadataRows(meta, columnCount) {
  const filters = Object.entries(meta.filters || {}).map(([key, value]) => `${key}: ${value}`).join(" | ") || "بدون فلاتر إضافية";
  return [
    row([`<Cell ss:MergeAcross="${Math.max(columnCount - 1, 0)}" ss:StyleID="Title"><Data ss:Type="String">${esc(meta.company || "NextEP ERP")}</Data></Cell>`], 30),
    row([`<Cell ss:MergeAcross="${Math.max(columnCount - 1, 0)}" ss:StyleID="Subtitle"><Data ss:Type="String">${esc(meta.reportTitle)}</Data></Cell>`], 24),
    row([cell("تم التصدير بواسطة", { style: "MetaLabel" }), cell(meta.generatedBy || "مستخدم النظام", { style: "Meta" })]),
    row([cell("تاريخ ووقت التصدير", { style: "MetaLabel" }), cell(meta.generatedAt || new Date().toISOString(), { style: "DateTime", type: "date" })]),
    row([cell("الفلاتر", { style: "MetaLabel" }), `<Cell ss:MergeAcross="${Math.max(columnCount - 2, 0)}" ss:StyleID="Meta"><Data ss:Type="String">${esc(filters)}</Data></Cell>`]),
    row(Array.from({ length: columnCount }, () => cell(""))),
  ];
}

function worksheet(sheet, meta) {
  const columns = sheet.columns || [];
  const rows = sheet.rows || [];
  const summary = sheet.summary || [];
  const widths = columns.map((col) => `<Column ss:AutoFitWidth="0" ss:Width="${col.width || 100}"/>`).join("");
  const summaryRows = summary.length ? [
    row([`<Cell ss:MergeAcross="${Math.max(columns.length - 1, 0)}" ss:StyleID="Section"><Data ss:Type="String">ملخص</Data></Cell>`]),
    ...summary.map((item) => row([
      cell(item.label, { style: "SummaryLabel" }),
      cell(item.value, { style: item.type === "currency" ? "CurrencyTotal" : "SummaryValue", type: item.type === "number" || item.type === "currency" ? "number" : undefined }),
    ])),
    row(Array.from({ length: columns.length }, () => cell(""))),
  ] : [];
  const header = row(columns.map((col) => cell(col.label, { style: "Header" })), 24);
  const dataRows = rows.map((record, index) => row(columns.map((col) => {
    const raw = typeof col.value === "function" ? col.value(record, index) : record[col.key];
    const style = col.type === "currency" ? "Currency" : col.type === "number" ? "Number" : col.type === "date" ? "Date" : col.type === "status" ? "Status" : "Text";
    return cell(raw, { style, type: col.type === "currency" || col.type === "number" ? "number" : col.type });
  })));
  const empty = rows.length ? "" : row([`<Cell ss:MergeAcross="${Math.max(columns.length - 1, 0)}" ss:StyleID="Empty"><Data ss:Type="String">لا توجد بيانات ضمن الفلاتر المحددة</Data></Cell>`]);
  const filterEnd = Math.max(rows.length + 1, 2);
  return `<Worksheet ss:Name="${esc(safeSheetName(sheet.name))}"><Table>${widths}${metadataRows(meta, columns.length).join("")}${summaryRows.join("")}${header}${dataRows.join("")}${empty}</Table><WorksheetOptions xmlns="urn:schemas-microsoft-com:office:excel"><FreezePanes/><FrozenNoSplit/><SplitHorizontal>1</SplitHorizontal><TopRowBottomPane>1</TopRowBottomPane><Selected/></WorksheetOptions><AutoFilter x:Range="R1C1:R${filterEnd}C${columns.length}" xmlns="urn:schemas-microsoft-com:office:excel"/></Worksheet>`;
}

const STYLES = `<Styles>
<Style ss:ID="Default" ss:Name="Normal"><Alignment ss:Vertical="Center" ss:ReadingOrder="RightToLeft"/><Font ss:FontName="Arial" ss:Size="10"/></Style>
<Style ss:ID="Title"><Alignment ss:Horizontal="Center" ss:Vertical="Center"/><Font ss:FontName="Arial" ss:Size="18" ss:Bold="1"/></Style>
<Style ss:ID="Subtitle"><Alignment ss:Horizontal="Center" ss:Vertical="Center"/><Font ss:FontName="Arial" ss:Size="14" ss:Bold="1"/></Style>
<Style ss:ID="MetaLabel"><Font ss:Bold="1"/><Interior ss:Color="#E7E6E6" ss:Pattern="Solid"/></Style>
<Style ss:ID="Meta"><Alignment ss:WrapText="1"/></Style>
<Style ss:ID="DateTime"><NumberFormat ss:Format="yyyy-mm-dd hh:mm"/></Style>
<Style ss:ID="Section"><Font ss:Bold="1" ss:Size="12"/><Interior ss:Color="#D9EAD3" ss:Pattern="Solid"/></Style>
<Style ss:ID="SummaryLabel"><Font ss:Bold="1"/><Interior ss:Color="#F3F6F4" ss:Pattern="Solid"/></Style>
<Style ss:ID="SummaryValue"><Font ss:Bold="1"/><NumberFormat ss:Format="#,##0.00"/></Style>
<Style ss:ID="CurrencyTotal"><Font ss:Bold="1"/><NumberFormat ss:Format="#,##0.00 [$ر.س.-ar-SA]"/></Style>
<Style ss:ID="Header"><Alignment ss:Horizontal="Center" ss:WrapText="1"/><Font ss:Bold="1" ss:Color="#FFFFFF"/><Interior ss:Color="#355E3B" ss:Pattern="Solid"/><Borders><Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1"/><Border ss:Position="Left" ss:LineStyle="Continuous" ss:Weight="1"/><Border ss:Position="Right" ss:LineStyle="Continuous" ss:Weight="1"/><Border ss:Position="Top" ss:LineStyle="Continuous" ss:Weight="1"/></Borders></Style>
<Style ss:ID="Text"><Alignment ss:WrapText="1"/><Borders><Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#D9D9D9"/></Borders></Style>
<Style ss:ID="Number"><NumberFormat ss:Format="#,##0.00"/><Borders><Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#D9D9D9"/></Borders></Style>
<Style ss:ID="Currency"><NumberFormat ss:Format="#,##0.00 [$ر.س.-ar-SA]"/><Borders><Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#D9D9D9"/></Borders></Style>
<Style ss:ID="Date"><NumberFormat ss:Format="yyyy-mm-dd"/><Borders><Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#D9D9D9"/></Borders></Style>
<Style ss:ID="Status"><Alignment ss:Horizontal="Center"/><Font ss:Bold="1"/><Interior ss:Color="#FFF2CC" ss:Pattern="Solid"/></Style>
<Style ss:ID="Empty"><Alignment ss:Horizontal="Center"/><Font ss:Italic="1" ss:Color="#777777"/></Style>
</Styles>`;

export function buildExcelWorkbook({ meta, sheets }) {
  if (!Array.isArray(sheets) || sheets.length === 0) throw new Error("Workbook requires at least one worksheet");
  return `<?xml version="1.0"?><?mso-application progid="Excel.Sheet"?><Workbook ${XML_NS}>${STYLES}${sheets.map((sheet) => worksheet(sheet, meta)).join("")}</Workbook>`;
}

export function downloadExcelWorkbook({ filename, meta, sheets }) {
  const xml = buildExcelWorkbook({ meta, sheets });
  const blob = new Blob(["\ufeff", xml], { type: "application/vnd.ms-excel;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = filename.endsWith(".xls") ? filename : `${filename}.xls`;
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  URL.revokeObjectURL(url);
}

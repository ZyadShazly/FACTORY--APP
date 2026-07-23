# Procurement printing

Purchase requests and purchase orders are printed from the selected procurement document modal.

The print stylesheet:

- hides the application shell and all non-document content;
- exposes only `.procurement-print-document`;
- removes modal height and overflow limits;
- hides action buttons;
- keeps table headers and rows print-safe on A4 portrait pages.

No database or workflow behavior is changed by this patch.

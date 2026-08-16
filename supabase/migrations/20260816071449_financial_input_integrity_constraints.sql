alter table public.daily_labor
  add constraint daily_labor_overtime_within_total_hours_check
  check (coalesce(overtime_hours, 0) <= coalesce(total_hours, 0));

alter table public.supplier_quote_items
  add constraint supplier_quote_items_discount_within_gross_check
  check (discount_amount <= quantity * unit_price),
  add constraint supplier_quote_items_line_total_nonnegative_check
  check (line_total >= 0);

alter table public.purchase_order_items
  add constraint purchase_order_items_discount_within_gross_check
  check (discount_amount <= quantity * unit_price),
  add constraint purchase_order_items_line_total_nonnegative_check
  check (line_total >= 0);

alter table public.supplier_invoice_lines
  add constraint supplier_invoice_lines_discount_within_gross_check
  check (discount_amount <= quantity * unit_price),
  add constraint supplier_invoice_lines_line_total_nonnegative_check
  check (line_total >= 0);

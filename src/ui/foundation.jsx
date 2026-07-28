import React, { Children, useEffect, useId, useRef } from "react";
import { Archive, Info, PackageOpen, X } from "lucide-react";

export const MAX_KPI_CARDS = 5;

function classNames(...values) {
  return values.filter(Boolean).join(" ");
}

export function PageHeader({
  eyebrow,
  title,
  description,
  primaryAction,
  secondaryActions,
  headingLevel = 2,
  className = "",
}) {
  const Heading = headingLevel === 1 ? "h1" : headingLevel === 3 ? "h3" : "h2";
  return (
    <header className={classNames("nui-page-header", className)}>
      <div className="nui-page-header__copy">
        {eyebrow && <span className="nui-eyebrow">{eyebrow}</span>}
        <Heading>{title}</Heading>
        {description && <p>{description}</p>}
      </div>
      {(primaryAction || secondaryActions) && (
        <div className="nui-page-header__actions">
          {secondaryActions && <div className="nui-secondary-actions">{secondaryActions}</div>}
          {primaryAction && <div className="nui-primary-action">{primaryAction}</div>}
        </div>
      )}
    </header>
  );
}

export function KpiGrid({ children, label = "مؤشرات الأداء", className = "" }) {
  const cards = Children.toArray(children);
  return (
    <section
      className={classNames("nui-kpi-grid", className)}
      aria-label={label}
      data-kpi-count={cards.length}
      data-max-kpis={MAX_KPI_CARDS}
    >
      {cards}
    </section>
  );
}

export function KpiCard({ label, value, hint, tone = "neutral", icon = null }) {
  return (
    <article className={classNames("nui-kpi-card", `is-${tone}`)}>
      <div className="nui-kpi-card__label">{icon}{label}</div>
      <strong>{value}</strong>
      {hint && <small>{hint}</small>}
    </article>
  );
}

export function PrimaryActionBar({
  primaryAction,
  children,
  label = "الإجراءات الرئيسية",
  sticky = true,
  className = "",
}) {
  return (
    <nav
      className={classNames("nui-primary-action-bar", sticky && "is-sticky", className)}
      aria-label={label}
    >
      <div className="nui-primary-action-bar__primary">{primaryAction}</div>
      {children && <div className="nui-primary-action-bar__secondary">{children}</div>}
    </nav>
  );
}

export function SearchFilterBar({
  value,
  onChange,
  placeholder = "ابحث...",
  searchLabel = "بحث",
  children,
  actions,
  className = "",
}) {
  return (
    <section className={classNames("nui-search-filter-bar", className)} aria-label="البحث والتصفية">
      <label className="nui-search-filter-bar__search">
        <span className="nui-visually-hidden">{searchLabel}</span>
        <input
          type="search"
          value={value}
          onChange={onChange}
          placeholder={placeholder}
          aria-label={searchLabel}
        />
      </label>
      {children && <div className="nui-search-filter-bar__filters">{children}</div>}
      {actions && <div className="nui-search-filter-bar__actions">{actions}</div>}
    </section>
  );
}

const STATUS_TONES = new Set(["success", "info", "warning", "danger", "neutral"]);

export function StatusBadge({ label, tone = "neutral", icon = null, className = "" }) {
  const safeTone = STATUS_TONES.has(tone) ? tone : "neutral";
  return (
    <span className={classNames("nui-status-badge", `is-${safeTone}`, className)}>
      {icon}
      <span>{label}</span>
    </span>
  );
}

export function EmptyState({
  title = "لا توجد بيانات",
  description = "لا توجد سجلات مطابقة في الوقت الحالي.",
  icon = <PackageOpen size={24} aria-hidden="true" />,
  action = null,
  className = "",
}) {
  return (
    <section className={classNames("nui-empty-state", className)} aria-label={title}>
      <div className="nui-empty-state__icon">{icon}</div>
      <strong>{title}</strong>
      {description && <p>{description}</p>}
      {action && <div className="nui-empty-state__action">{action}</div>}
    </section>
  );
}

export function DetailsDrawer({
  open,
  title,
  description,
  children,
  footer,
  onClose,
  closeLabel = "إغلاق التفاصيل",
  className = "",
}) {
  const titleId = useId();
  const descriptionId = useId();
  const closeButtonRef = useRef(null);
  useEffect(() => {
    if (!open) return undefined;
    const previousFocus = document.activeElement;
    const closeOnEscape = (event) => {
      if (event.key === "Escape") onClose?.();
    };
    window.addEventListener("keydown", closeOnEscape);
    closeButtonRef.current?.focus();
    return () => {
      window.removeEventListener("keydown", closeOnEscape);
      previousFocus?.focus?.();
    };
  }, [onClose, open]);

  if (!open) return null;
  return (
    <div className="nui-drawer-layer">
      <button type="button" className="nui-drawer-backdrop" aria-label={closeLabel} onClick={onClose} />
      <aside
        className={classNames("nui-details-drawer", className)}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        aria-describedby={description ? descriptionId : undefined}
      >
        <header>
          <div>
            <h2 id={titleId}>{title}</h2>
            {description && <p id={descriptionId}>{description}</p>}
          </div>
          <button ref={closeButtonRef} type="button" className="nui-icon-button" aria-label={closeLabel} onClick={onClose}>
            <X size={18} aria-hidden="true" />
          </button>
        </header>
        <div className="nui-details-drawer__body">{children}</div>
        {footer && <footer>{footer}</footer>}
      </aside>
    </div>
  );
}

export function ArchiveSection({
  title = "السجل والأرشيف",
  count,
  children,
  defaultOpen = false,
  helpText,
  className = "",
}) {
  return (
    <details className={classNames("nui-archive-section", className)} open={defaultOpen}>
      <summary>
        <Archive size={17} aria-hidden="true" />
        <span>{title}</span>
        {Number.isFinite(Number(count)) && <b>{Number(count).toLocaleString("ar-EG")}</b>}
      </summary>
      {helpText && <p className="nui-archive-section__help">{helpText}</p>}
      <div className="nui-archive-section__body">{children}</div>
    </details>
  );
}

export function DependencySummary({
  items = [],
  title = "الارتباطات",
  emptyText = "لا توجد سجلات مرتبطة.",
  className = "",
}) {
  return (
    <section className={classNames("nui-dependency-summary", className)} aria-label={title}>
      <h3>{title}</h3>
      {items.length === 0 ? <p>{emptyText}</p> : (
        <ul>
          {items.map((item) => (
            <li key={item.id ?? item.label}>
              <div>
                <strong>{item.label}</strong>
                {item.description && <span>{item.description}</span>}
              </div>
              <b aria-label={`${item.label}: ${Number(item.count || 0).toLocaleString("ar-EG")}`}>
                {Number(item.count || 0).toLocaleString("ar-EG")}
              </b>
              {item.action}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

export function HelpText({ children, title = "معلومة", tone = "info", className = "" }) {
  return (
    <aside className={classNames("nui-help-text", `is-${tone}`, className)} aria-label={title}>
      <Info size={17} aria-hidden="true" />
      <div><strong>{title}</strong><span>{children}</span></div>
    </aside>
  );
}

export function ResponsiveTable({ headers, children, caption, className = "" }) {
  return (
    <div className={classNames("nui-responsive-table", className)}>
      <table>
        {caption && <caption>{caption}</caption>}
        <thead><tr>{headers.map((header, index) => <th key={header.key ?? index}>{header.label ?? header}</th>)}</tr></thead>
        <tbody>{children}</tbody>
      </table>
    </div>
  );
}

export function ResponsiveCardGrid({ children, className = "", label }) {
  return (
    <section className={classNames("nui-responsive-card-grid", className)} aria-label={label}>
      {children}
    </section>
  );
}

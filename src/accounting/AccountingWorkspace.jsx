import React, { useCallback, useEffect, useMemo, useState } from "react";
import {
  ChevronDown,
  ChevronLeft,
  CirclePlus,
  Edit3,
  FolderTree,
  RefreshCw,
  Search,
  ShieldCheck,
} from "lucide-react";
import { supabase } from "../supabaseClient";
import { JournalWorkspace } from "./JournalWorkspace";
import { AccountingReportsWorkspace } from "./AccountingReportsWorkspace";
import { AccountingMappingsWorkspace } from "./AccountingMappingsWorkspace";
import "./accountingWorkspace.css";

const TYPE_LABELS = {
  asset: "أصول",
  liability: "التزامات",
  equity: "حقوق ملكية",
  revenue: "إيرادات",
  cost_of_sales: "تكلفة مبيعات",
  expense: "مصروفات",
};

const EMPTY_EDITOR = {
  mode: "create",
  id: "",
  account_code: "",
  name_ar: "",
  name_en: "",
  parent_id: "",
  account_type: "asset",
  is_posting: true,
  is_contra: false,
  is_active: true,
  description: "",
};

function accountSearchText(account) {
  return [
    account.account_code,
    account.name_ar,
    account.name_en,
    TYPE_LABELS[account.account_type],
  ].filter(Boolean).join(" ").toLowerCase();
}

function buildVisibleRows(accounts, expanded, query, accountType) {
  const byId = new Map(accounts.map((row) => [row.id, row]));
  const children = new Map();

  for (const row of accounts) {
    const key = row.parent_id || "__root__";
    if (!children.has(key)) children.set(key, []);
    children.get(key).push(row);
  }

  for (const rows of children.values()) {
    rows.sort((a, b) => String(a.account_code).localeCompare(String(b.account_code), "en", { numeric: true }));
  }

  const normalized = query.trim().toLowerCase();
  const filtering = Boolean(normalized || accountType);
  const included = new Set();

  if (filtering) {
    for (const row of accounts) {
      const matchesText = !normalized || accountSearchText(row).includes(normalized);
      const matchesType = !accountType || row.account_type === accountType;
      if (!matchesText || !matchesType) continue;
      let current = row;
      while (current) {
        included.add(current.id);
        current = current.parent_id ? byId.get(current.parent_id) : null;
      }
    }
  }

  const output = [];
  const visit = (row, level) => {
    if (filtering && !included.has(row.id)) return;
    output.push({ ...row, ui_level: level });
    const shouldOpen = filtering || expanded.has(row.id);
    if (!shouldOpen) return;
    for (const child of children.get(row.id) || []) visit(child, level + 1);
  };

  for (const root of children.get("__root__") || []) visit(root, 1);
  return output;
}

function Notice({ type = "info", children }) {
  return <div className={`accounting-notice ${type}`} role={type === "error" ? "alert" : "status"}>{children}</div>;
}

function AccountEditor({ editor, accounts, onChange, onParentChange, onClose, onSave, busy }) {
  const [parentQuery, setParentQuery] = useState("");
  const parent = accounts.find((row) => row.id === editor.parent_id);
  const normalizedParentQuery = parentQuery.trim().toLowerCase();

  const parentCandidates = useMemo(() => {
    if (!normalizedParentQuery) return [];
    const blocked = new Set(editor.id ? [editor.id] : []);
    if (editor.id) {
      let changed = true;
      while (changed) {
        changed = false;
        for (const row of accounts) {
          if (row.parent_id && blocked.has(row.parent_id) && !blocked.has(row.id)) {
            blocked.add(row.id);
            changed = true;
          }
        }
      }
    }
    return accounts
      .filter((row) => row.is_active && !blocked.has(row.id))
      .filter((row) => accountSearchText(row).includes(normalizedParentQuery))
      .sort((a, b) => String(a.account_code).localeCompare(String(b.account_code), "en", { numeric: true }))
      .slice(0, 15);
  }, [accounts, editor.id, normalizedParentQuery]);

  const selectParent = (row) => {
    onParentChange(row || null);
    setParentQuery("");
  };

  return <div className="accounting-modal-layer" role="dialog" aria-modal="true" aria-label={editor.mode === "edit" ? "تعديل الحساب" : "إضافة حساب"}>
    <div className="accounting-modal">
      <div className="accounting-modal-head">
        <div>
          <span>شجرة الحسابات</span>
          <h3>{editor.mode === "edit" ? "تعديل الحساب" : editor.parent_id ? "إضافة حساب فرعي" : "إضافة حساب"}</h3>
        </div>
        <button type="button" className="accounting-close" onClick={onClose}>×</button>
      </div>

      <div className="accounting-form-grid">
        <label>كود الحساب
          <input
            value={editor.account_code}
            readOnly={editor.mode !== "edit"}
            onChange={(e) => editor.mode === "edit" && onChange({ account_code: e.target.value })}
            placeholder={editor.mode === "edit" ? "مثال: 1.1.08" : "جارٍ توليد الكود تلقائيًا..."}
          />
          {editor.mode !== "edit" && <small className="accounting-field-hint">تلقائي وتسلسلي داخل الحساب الأب. بعد 99 يكمل 100 ثم 101 بدون حد من رقمين.</small>}
        </label>
        <label>الاسم بالعربي
          <input value={editor.name_ar} onChange={(e) => onChange({ name_ar: e.target.value })} />
        </label>
        <label>الاسم بالإنجليزي
          <input value={editor.name_en} onChange={(e) => onChange({ name_en: e.target.value })} />
        </label>

        <label className="accounting-span-2">الحساب الأب
          {parent && <div className="accounting-parent-selected">
            <span><b>{parent.account_code}</b> · {parent.name_ar}</span>
            <button type="button" onClick={() => selectParent(null)}>جعله حساب رئيسي</button>
          </div>}
          <div className="accounting-parent-search">
            <Search size={15}/>
            <input
              value={parentQuery}
              onChange={(e) => setParentQuery(e.target.value)}
              placeholder="ابحث بكود أو اسم الحساب الأب..."
              autoComplete="off"
            />
          </div>
          {normalizedParentQuery && <div className="accounting-parent-results" role="listbox" aria-label="نتائج البحث عن الحساب الأب">
            {parentCandidates.map((row) => <button
              type="button"
              key={row.id}
              role="option"
              aria-selected={row.id === editor.parent_id}
              onClick={() => selectParent(row)}
            >
              <b>{row.account_code}</b>
              <span>{row.name_ar}</span>
              <small>{row.name_en || TYPE_LABELS[row.account_type] || row.account_type}</small>
            </button>)}
            {!parentCandidates.length && <div className="accounting-parent-empty">لا توجد حسابات مطابقة. جرّب جزءًا من الكود أو الاسم.</div>}
          </div>}
          {!normalizedParentQuery && !parent && <small className="accounting-field-hint">اتركه بدون اختيار لإنشاء حساب رئيسي، أو اكتب للبحث بدل التمرير في قائمة طويلة.</small>}
        </label>

        <label>نوع الحساب
          <select value={editor.account_type} disabled={Boolean(parent)} onChange={(e) => onChange({ account_type: e.target.value })}>
            {Object.entries(TYPE_LABELS).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
          </select>
        </label>
        <label>طبيعة الحساب
          <select value={editor.is_posting ? "posting" : "group"} onChange={(e) => onChange({ is_posting: e.target.value === "posting" })}>
            <option value="posting">حساب حركة — يقبل قيود</option>
            <option value="group">حساب تجميعي — لا يقبل قيود</option>
          </select>
        </label>
        <label className="accounting-check">
          <input type="checkbox" checked={editor.is_contra} onChange={(e) => onChange({ is_contra: e.target.checked })} />
          <span>حساب مقابل Contra</span>
        </label>
        {editor.mode === "edit" && <label className="accounting-check">
          <input type="checkbox" checked={editor.is_active} onChange={(e) => onChange({ is_active: e.target.checked })} />
          <span>الحساب نشط</span>
        </label>}
        <label className="accounting-span-2">الوصف
          <textarea value={editor.description} onChange={(e) => onChange({ description: e.target.value })} rows={3} />
        </label>
      </div>

      <div className="accounting-modal-actions">
        <button type="button" className="accounting-button ghost" onClick={onClose}>رجوع</button>
        <button type="button" className="accounting-button primary" disabled={busy} onClick={onSave}>
          {busy ? "جارِ الحفظ..." : "حفظ"}
        </button>
      </div>
    </div>
  </div>;
}

export function AccountingWorkspace({ profile, permissions, projects = [], onNavigate }) {
  const [accounts, setAccounts] = useState([]);
  const [expanded, setExpanded] = useState(new Set());
  const [query, setQuery] = useState("");
  const [accountType, setAccountType] = useState("");
  const [editor, setEditor] = useState(null);
  const [conversion, setConversion] = useState(null);
  const [state, setState] = useState({ loading: true, busy: false, error: "", success: "" });
  const [section, setSection] = useState("accounts");

  const canManage = Boolean(permissions?.accounting_accounts_manage);
  const isOwner = profile?.role === "owner";

  const load = useCallback(async () => {
    setState((current) => ({ ...current, loading: true, error: "" }));
    const result = await supabase.rpc("get_accounting_accounts");
    if (result.error) {
      setAccounts([]);
      setState((current) => ({ ...current, loading: false, error: result.error.message || "تعذر تحميل شجرة الحسابات." }));
      return;
    }
    const rows = Array.isArray(result.data) ? result.data : [];
    setAccounts(rows);
    setExpanded((current) => current.size ? current : new Set(rows.filter((row) => Number(row.child_count || 0) > 0).map((row) => row.id)));
    setState((current) => ({ ...current, loading: false }));
  }, []);

  useEffect(() => { void load(); }, [load]);

  const rows = useMemo(
    () => buildVisibleRows(accounts, expanded, query, accountType),
    [accounts, expanded, query, accountType],
  );

  const patchEditor = (patch) => setEditor((current) => ({ ...current, ...patch }));

  const suggestAccountCode = useCallback(async (parentId = "") => {
    const result = await supabase.rpc("get_next_accounting_account_code", {
      target_parent: parentId || null,
    });
    if (result.error) {
      setState((current) => ({ ...current, error: result.error.message || "تعذر توليد كود الحساب تلقائيًا." }));
      return;
    }
    setEditor((current) => current && current.mode === "create" && current.parent_id === parentId
      ? { ...current, account_code: String(result.data || "") }
      : current);
  }, []);

  const openCreate = (parent = null) => {
    const parentId = parent?.id || "";
    setEditor({
      ...EMPTY_EDITOR,
      parent_id: parentId,
      account_type: parent?.account_type || "asset",
      account_code: "",
    });
    setState((current) => ({ ...current, error: "", success: "" }));
    void suggestAccountCode(parentId);
  };

  const changeEditorParent = (nextParent = null) => {
    const parentId = nextParent?.id || "";
    setEditor((current) => current ? {
      ...current,
      parent_id: parentId,
      ...(nextParent ? { account_type: nextParent.account_type } : {}),
      ...(current.mode === "create" ? { account_code: "" } : {}),
    } : current);
    if (editor?.mode === "create") void suggestAccountCode(parentId);
  };

  const openEdit = (row) => {
    setEditor({
      mode: "edit",
      id: row.id,
      account_code: row.account_code || "",
      name_ar: row.name_ar || "",
      name_en: row.name_en || "",
      parent_id: row.parent_id || "",
      account_type: row.account_type,
      is_posting: Boolean(row.is_posting),
      is_contra: Boolean(row.is_contra),
      is_active: Boolean(row.is_active),
      description: row.description || "",
    });
    setState((current) => ({ ...current, error: "", success: "" }));
  };

  const save = async () => {
    if (!editor?.name_ar.trim() || (editor.mode === "edit" && !editor.account_code.trim())) {
      setState((current) => ({ ...current, error: editor.mode === "edit" ? "كود الحساب والاسم بالعربي مطلوبان." : "اسم الحساب بالعربي مطلوب." }));
      return;
    }
    setState((current) => ({ ...current, busy: true, error: "", success: "" }));
    const payload = {
      ...(editor.mode === "edit" ? { account_code: editor.account_code.trim() } : {}),
      name_ar: editor.name_ar.trim(),
      name_en: editor.name_en.trim() || null,
      parent_id: editor.parent_id || null,
      account_type: editor.account_type,
      is_posting: Boolean(editor.is_posting),
      is_contra: Boolean(editor.is_contra),
      description: editor.description.trim() || null,
      ...(editor.mode === "edit" ? { is_active: Boolean(editor.is_active) } : {}),
    };
    const result = editor.mode === "edit"
      ? await supabase.rpc("update_accounting_account", { target_id: editor.id, payload })
      : await supabase.rpc("create_accounting_account", { payload });

    if (result.error) {
      setState((current) => ({ ...current, busy: false, error: result.error.message || "تعذر حفظ الحساب." }));
      return;
    }

    const savedAccount = result.data;
    setEditor(null);
    await load();
    setState((current) => ({ ...current, busy: false, success: editor.mode === "edit"
      ? "تم تحديث الحساب."
      : `تمت إضافة الحساب بالكود ${savedAccount?.account_code || "التلقائي"}.` }));
  };

  const toggleActive = async (row) => {
    setState((current) => ({ ...current, busy: true, error: "", success: "" }));
    const result = await supabase.rpc("update_accounting_account", {
      target_id: row.id,
      payload: { is_active: !row.is_active },
    });
    if (result.error) {
      setState((current) => ({ ...current, busy: false, error: result.error.message || "تعذر تغيير حالة الحساب." }));
      return;
    }
    await load();
    setState((current) => ({ ...current, busy: false, success: row.is_active ? "تم تعطيل الحساب." : "تم تفعيل الحساب." }));
  };

  const convertToGroup = async () => {
    if (!conversion?.reason?.trim()) {
      setState((current) => ({ ...current, error: "سبب التحويل إلى حساب تجميعي مطلوب." }));
      return;
    }
    setState((current) => ({ ...current, busy: true, error: "", success: "" }));
    const result = await supabase.rpc("owner_convert_account_to_group", {
      target_id: conversion.row.id,
      reason: conversion.reason.trim(),
    });
    if (result.error) {
      setState((current) => ({ ...current, busy: false, error: result.error.message || "تعذر تحويل الحساب." }));
      return;
    }
    setConversion(null);
    await load();
    setState((current) => ({ ...current, busy: false, success: "تم تحويل الحساب إلى حساب تجميعي مع الاحتفاظ بتاريخه." }));
  };

  const toggleExpanded = (id) => {
    setExpanded((current) => {
      const next = new Set(current);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  };

  return <div className="accounting-page">
    <header className="page-header">
      <div className="page-header-copy">
        <div className="page-eyebrow"><FolderTree size={14}/><span>المالية والمحاسبة</span></div>
        <h2>المحاسبة</h2>
        <p>شجرة حسابات مرنة ودفتر قيود محمي. الربط التلقائي مع العمليات التشغيلية سيأتي في مرحلة مستقلة.</p>
      </div>
      {section === "accounts" && <div className="accounting-head-actions">
        <button type="button" className="accounting-button ghost" onClick={load} disabled={state.loading}><RefreshCw size={15}/>تحديث</button>
        {canManage && <button type="button" className="accounting-button primary" onClick={() => openCreate()}><CirclePlus size={16}/>إضافة حساب</button>}
      </div>}
    </header>

    <nav className="accounting-main-tabs" aria-label="أقسام المحاسبة">
      <button type="button" className={section === "accounts" ? "active" : ""} onClick={() => setSection("accounts")}>شجرة الحسابات</button>
      <button type="button" className={section === "journals" ? "active" : ""} onClick={() => setSection("journals")}>القيود اليومية</button>
      {permissions?.accounting_reports_view && <button type="button" className={section === "reports" ? "active" : ""} onClick={() => setSection("reports")}>التقارير المحاسبية</button>}
      <button type="button" className={section === "mappings" ? "active" : ""} onClick={() => setSection("mappings")}>ربط الحسابات</button>
    </nav>

    {section === "journals" ? <JournalWorkspace accounts={accounts} profile={profile} permissions={permissions} onNavigate={onNavigate}/> :
     section === "reports" ? <AccountingReportsWorkspace accounts={accounts} projects={projects}/> :
     section === "mappings" ? <AccountingMappingsWorkspace accounts={accounts} profile={profile}/> : <>

    <div className="accounting-stage-note">
      <ShieldCheck size={17}/>
      <span>المحاسبة غير مفعلة للترحيل التلقائي بعد. هذه الشاشة لإعداد شجرة الحسابات فقط.</span>
    </div>

    <section className="accounting-panel">
      <div className="accounting-toolbar">
        <label className="accounting-search"><Search size={16}/><input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="بحث بالكود أو اسم الحساب..." /></label>
        <select value={accountType} onChange={(e) => setAccountType(e.target.value)}>
          <option value="">كل أنواع الحسابات</option>
          {Object.entries(TYPE_LABELS).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
        </select>
        <button type="button" className="accounting-button ghost" onClick={() => setExpanded(new Set(accounts.filter((row) => Number(row.child_count || 0) > 0).map((row) => row.id)))}>فتح الكل</button>
        <button type="button" className="accounting-button ghost" onClick={() => setExpanded(new Set())}>طي الكل</button>
      </div>

      {state.error && <Notice type="error">{state.error}</Notice>}
      {state.success && <Notice type="success">{state.success}</Notice>}
      {state.loading ? <div className="accounting-empty">جارِ تحميل شجرة الحسابات...</div> :
        rows.length === 0 ? <div className="accounting-empty">لا توجد حسابات مطابقة.</div> :
        <div className="accounting-tree" role="tree">
          <div className="accounting-tree-head">
            <span>الحساب</span><span>النوع</span><span>الحالة</span><span>الرصيد</span><span>الإجراءات</span>
          </div>
          {rows.map((row) => {
            const hasChildren = Number(row.child_count || 0) > 0;
            return <div className={`accounting-tree-row ${row.is_active ? "" : "inactive"}`} key={row.id} role="treeitem" aria-level={row.ui_level}>
              <div className="accounting-account-cell" style={{ "--tree-depth": Math.max(0, row.ui_level - 1) }}>
                <button type="button" className={`accounting-expand ${hasChildren ? "" : "placeholder"}`} onClick={() => hasChildren && toggleExpanded(row.id)} aria-label={hasChildren ? "فتح أو طي الحساب" : undefined}>
                  {hasChildren ? (expanded.has(row.id) ? <ChevronDown size={16}/> : <ChevronLeft size={16}/>) : <span/>}
                </button>
                <div><strong>{row.account_code} · {row.name_ar}</strong><small>{row.name_en || "—"}</small></div>
              </div>
              <div><span className="accounting-badge">{TYPE_LABELS[row.account_type] || row.account_type}</span></div>
              <div className="accounting-status-stack">
                <span className={`accounting-badge ${row.is_posting ? "posting" : "group"}`}>{row.is_posting ? "حركة" : "تجميعي"}</span>
                <span className={`accounting-badge ${row.is_active ? "active" : "disabled"}`}>{row.is_active ? "نشط" : "معطل"}</span>
              </div>
              <div className="accounting-balance-placeholder">—</div>
              <div className="accounting-row-actions">
                {canManage && <button type="button" onClick={() => openCreate(row)} title="إضافة حساب فرعي"><CirclePlus size={15}/><span>فرعي</span></button>}
                {canManage && <button type="button" onClick={() => openEdit(row)}><Edit3 size={15}/><span>تعديل</span></button>}
                {canManage && <button type="button" onClick={() => toggleActive(row)} disabled={state.busy}>{row.is_active ? "تعطيل" : "تفعيل"}</button>}
                {isOwner && row.is_posting && Boolean(row.has_activity) && <button type="button" onClick={() => setConversion({ row, reason: "" })}>تحويل لتجميعي</button>}
              </div>
            </div>;
          })}
        </div>
      }
      <div className="accounting-footnote">الرصيد سيظهر هنا بعد تشغيل دفتر الأستاذ والقيود. الحسابات التجميعية لا تقبل قيودًا مباشرة.</div>
    </section>

    {editor && <AccountEditor
      editor={editor}
      accounts={accounts}
      onChange={patchEditor}
      onParentChange={changeEditorParent}
      onClose={() => setEditor(null)}
      onSave={save}
      busy={state.busy}
    />}

    {conversion && <div className="accounting-modal-layer" role="dialog" aria-modal="true" aria-label="تحويل الحساب إلى تجميعي">
      <div className="accounting-modal compact">
        <div className="accounting-modal-head"><div><span>Owner / Master</span><h3>تحويل {conversion.row.account_code} إلى حساب تجميعي</h3></div><button type="button" className="accounting-close" onClick={() => setConversion(null)}>×</button></div>
        <p>الحركات التاريخية ستظل على الحساب، لكن لن يقبل قيودًا جديدة بعد التحويل ويمكنك إضافة حسابات تحته.</p>
        <label>سبب التحويل
          <textarea rows={4} value={conversion.reason} onChange={(e) => setConversion((current) => ({ ...current, reason: e.target.value }))} />
        </label>
        <div className="accounting-modal-actions">
          <button type="button" className="accounting-button ghost" onClick={() => setConversion(null)}>رجوع</button>
          <button type="button" className="accounting-button primary" disabled={state.busy} onClick={convertToGroup}>تأكيد التحويل</button>
        </div>
      </div>
    </div>}
    </>}
  </div>;
}

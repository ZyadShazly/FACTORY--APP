import React, { useCallback, useEffect, useMemo, useState } from "react";
import { BookOpenText, CirclePlus, Pencil, Plus, RefreshCw, RotateCcw, Send, Trash2 } from "lucide-react";
import { supabase } from "../supabaseClient";
import "./accountingJournal.css";

const STATUS_LABELS = { draft: "مسودة", posted: "مرحّل", reversed: "معكوس" };
const ORIGIN_LABELS = { manual: "يدوي", opening: "افتتاحي", system: "تلقائي", reversal: "عكسي" };
const today = () => new Date().toISOString().slice(0, 10);
const blankLine = () => ({ account_id: "", debit: "", credit: "", description: "" });
const amount = (value) => { const n = Number(value); return Number.isFinite(n) ? n : 0; };

function periodOpen(periods, date) {
  return periods.some((p) => p.status === "open" && date >= p.period_start && date <= p.period_end);
}

function JournalEditor({ editor, setEditor, accounts, projects, onClose, onSave, busy, isOwner }) {
  const legacyIds = new Set((editor.original_lines || []).map((line) => line.account_id));
  const available = accounts.filter((account) => (account.is_active && account.is_posting) || legacyIds.has(account.id));
  const totalDebit = editor.lines.reduce((sum, line) => sum + amount(line.debit), 0);
  const totalCredit = editor.lines.reduce((sum, line) => sum + amount(line.credit), 0);
  const difference = totalDebit - totalCredit;

  const patch = (key, value) => setEditor((current) => ({ ...current, [key]: value }));
  const patchLine = (index, key, value) => setEditor((current) => ({
    ...current,
    lines: current.lines.map((line, lineIndex) => lineIndex === index ? {
      ...line,
      [key]: value,
      ...(key === "debit" && amount(value) > 0 ? { credit: "" } : {}),
      ...(key === "credit" && amount(value) > 0 ? { debit: "" } : {}),
    } : line),
  }));

  return <div className="accounting-modal-layer" role="dialog" aria-modal="true" aria-label="محرر القيد">
    <div className="accounting-modal journal-editor-modal">
      <div className="accounting-modal-head">
        <div>
          <span>{editor.mode === "owner-edit" ? "Owner / Master" : editor.mode === "draft-edit" ? "تعديل مسودة" : "قيد جديد"}</span>
          <h3>{editor.entry_number || "قيد يومية جديد"}</h3>
        </div>
        <button type="button" className="accounting-close" onClick={onClose}>×</button>
      </div>

      <div className="journal-header-grid">
        <label>التاريخ
          <input type="date" value={editor.entry_date} onChange={(event) => patch("entry_date", event.target.value)}/>
        </label>
        <label>المرجع
          <input value={editor.reference} onChange={(event) => patch("reference", event.target.value)}/>
        </label>
        <label className="journal-span-2">البيان
          <input value={editor.description} onChange={(event) => patch("description", event.target.value)}/>
        </label>
        <label>المشروع
          <select value={editor.project_id} onChange={(event) => patch("project_id", event.target.value)}>
            <option value="">بدون مشروع</option>
            {projects.map((project) => <option key={project.id} value={project.id}>
              {(project.project_code ? project.project_code + " · " : "") + (project.project_name || project.name || "")}
            </option>)}
          </select>
        </label>
        {editor.mode === "create" && isOwner && <label>نوع القيد
          <select value={editor.entry_origin} onChange={(event) => patch("entry_origin", event.target.value)}>
            <option value="manual">قيد يدوي</option>
            <option value="opening">قيد افتتاحي</option>
          </select>
        </label>}
      </div>

      <div className="journal-lines-wrap">
        <div className="journal-lines-head"><span>الحساب</span><span>مدين</span><span>دائن</span><span>البيان</span><span/></div>
        {editor.lines.map((line, index) => <div className="journal-line" key={line.id || index}>
          <select value={line.account_id} onChange={(event) => patchLine(index, "account_id", event.target.value)}>
            <option value="">اختر الحساب</option>
            {available.map((account) => <option key={account.id} value={account.id}>
              {account.account_code + " · " + account.name_ar + (!account.is_posting ? " · تاريخي" : "")}
            </option>)}
          </select>
          <input inputMode="decimal" type="number" min="0" step="0.01" value={line.debit} onChange={(event) => patchLine(index, "debit", event.target.value)} placeholder="0.00"/>
          <input inputMode="decimal" type="number" min="0" step="0.01" value={line.credit} onChange={(event) => patchLine(index, "credit", event.target.value)} placeholder="0.00"/>
          <input value={line.description || ""} onChange={(event) => patchLine(index, "description", event.target.value)} placeholder="بيان السطر"/>
          <button type="button" className="journal-icon-button" disabled={editor.lines.length <= 2} onClick={() => setEditor((current) => ({ ...current, lines: current.lines.filter((_, lineIndex) => lineIndex !== index) }))}>
            <Trash2 size={15}/>
          </button>
        </div>)}
        <button type="button" className="accounting-button ghost journal-add-line" onClick={() => setEditor((current) => ({ ...current, lines: [...current.lines, blankLine()] }))}>
          <Plus size={15}/>سطر جديد
        </button>
      </div>

      <div className="journal-totals">
        <span>إجمالي المدين <b>{totalDebit.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</b></span>
        <span>إجمالي الدائن <b>{totalCredit.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</b></span>
        <span className={Math.abs(difference) < 0.005 ? "balanced" : "unbalanced"}>الفرق <b>{Math.abs(difference).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</b></span>
      </div>

      {editor.mode === "owner-edit" && <label className="journal-master-reason">سبب تعديل القيد المرحّل
        <textarea rows={3} value={editor.edit_reason} onChange={(event) => patch("edit_reason", event.target.value)} placeholder="السبب إلزامي ويُحفظ في سجل المراجعات"/>
      </label>}

      <div className="accounting-modal-actions">
        <button type="button" className="accounting-button ghost" onClick={onClose}>رجوع</button>
        <button type="button" className="accounting-button primary" disabled={busy} onClick={onSave}>{busy ? "جارِ الحفظ..." : "حفظ"}</button>
      </div>
    </div>
  </div>;
}

export function AccountingJournalPanel({ profile, permissions, projects = [] }) {
  const [accounts, setAccounts] = useState([]);
  const [workspace, setWorkspace] = useState({ settings: {}, periods: [], journals: [] });
  const [range, setRange] = useState({ from: "", to: "" });
  const [editor, setEditor] = useState(null);
  const [reversal, setReversal] = useState(null);
  const [state, setState] = useState({ loading: true, busy: false, error: "", success: "" });

  const isOwner = profile?.role === "owner";
  const canCreate = Boolean(permissions?.accounting_journal_create);
  const canPost = Boolean(permissions?.accounting_journal_post);
  const canReverse = Boolean(permissions?.accounting_journal_reverse);

  const load = useCallback(async () => {
    setState((current) => ({ ...current, loading: true, error: "" }));
    const [journalResult, accountsResult] = await Promise.all([
      supabase.rpc("get_accounting_journal_workspace", { date_from: range.from || null, date_to: range.to || null }),
      supabase.rpc("get_accounting_accounts"),
    ]);

    const error = journalResult.error || accountsResult.error;
    if (error) {
      setState((current) => ({ ...current, loading: false, error: error.message || "تعذر تحميل القيود." }));
      return;
    }

    setWorkspace(journalResult.data || { settings: {}, periods: [], journals: [] });
    setAccounts(Array.isArray(accountsResult.data) ? accountsResult.data : []);
    setState((current) => ({ ...current, loading: false }));
  }, [range.from, range.to]);

  useEffect(() => { void load(); }, [load]);

  const startEditor = (row = null, mode = "create") => {
    const lines = row?.lines?.map((line) => ({
      id: line.id,
      account_id: line.account_id || "",
      debit: Number(line.debit || 0) > 0 ? String(line.debit) : "",
      credit: Number(line.credit || 0) > 0 ? String(line.credit) : "",
      description: line.description || "",
    })) || [blankLine(), blankLine()];

    setEditor({
      mode,
      id: row?.id || "",
      entry_number: row?.entry_number || "",
      entry_date: row?.entry_date || today(),
      reference: row?.reference || "",
      description: row?.description || "",
      project_id: row?.project_id || "",
      entry_origin: row?.entry_origin || "manual",
      lines,
      original_lines: row?.lines || [],
      edit_reason: "",
    });
    setState((current) => ({ ...current, error: "", success: "" }));
  };

  const saveEditor = async () => {
    if (!editor.description.trim()) {
      setState((current) => ({ ...current, error: "بيان القيد مطلوب." }));
      return;
    }
    if (editor.lines.length < 2 || editor.lines.some((line) => !line.account_id)) {
      setState((current) => ({ ...current, error: "القيد يحتاج سطرين على الأقل وكل سطر يجب أن يحتوي حسابًا." }));
      return;
    }
    if (editor.mode === "owner-edit" && !editor.edit_reason.trim()) {
      setState((current) => ({ ...current, error: "سبب تعديل القيد المرحّل مطلوب." }));
      return;
    }

    const payload = {
      entry_date: editor.entry_date,
      reference: editor.reference.trim() || null,
      description: editor.description.trim(),
      project_id: editor.project_id || null,
      entry_origin: editor.entry_origin,
      lines: editor.lines.map((line) => ({
        account_id: line.account_id,
        debit: amount(line.debit),
        credit: amount(line.credit),
        description: (line.description || "").trim() || null,
      })),
    };

    setState((current) => ({ ...current, busy: true, error: "", success: "" }));

    let result;
    if (editor.mode === "draft-edit") {
      result = await supabase.rpc("update_accounting_journal_draft", { target_id: editor.id, payload });
    } else if (editor.mode === "owner-edit") {
      result = await supabase.rpc("owner_edit_posted_accounting_journal", { target_id: editor.id, payload, edit_reason: editor.edit_reason.trim() });
    } else {
      result = await supabase.rpc("create_accounting_journal", { payload });
    }

    if (result.error) {
      setState((current) => ({ ...current, busy: false, error: result.error.message || "تعذر حفظ القيد." }));
      return;
    }

    const mode = editor.mode;
    setEditor(null);
    await load();
    setState((current) => ({
      ...current,
      busy: false,
      success: mode === "owner-edit" ? "تم تعديل القيد المرحّل وتحديث أثره المحاسبي." : "تم حفظ القيد.",
    }));
  };

  const post = async (row) => {
    setState((current) => ({ ...current, busy: true, error: "", success: "" }));
    const result = await supabase.rpc("post_accounting_journal", { target_id: row.id });
    if (result.error) {
      setState((current) => ({ ...current, busy: false, error: result.error.message || "تعذر ترحيل القيد." }));
      return;
    }
    await load();
    setState((current) => ({ ...current, busy: false, success: "تم ترحيل القيد " + row.entry_number + "." }));
  };

  const runReversal = async () => {
    if (!reversal?.reason?.trim()) {
      setState((current) => ({ ...current, error: "سبب العكس مطلوب." }));
      return;
    }
    setState((current) => ({ ...current, busy: true, error: "", success: "" }));
    const result = await supabase.rpc("reverse_accounting_journal", {
      target_id: reversal.row.id,
      reversal_date: reversal.date,
      reason: reversal.reason.trim(),
    });
    if (result.error) {
      setState((current) => ({ ...current, busy: false, error: result.error.message || "تعذر عكس القيد." }));
      return;
    }
    const entryNumber = reversal.row.entry_number;
    setReversal(null);
    await load();
    setState((current) => ({ ...current, busy: false, success: "تم عكس القيد " + entryNumber + " بقيد عكسي مستقل." }));
  };

  const settings = workspace.settings || {};
  const periods = workspace.periods || [];
  const journals = workspace.journals || [];
  const postingEnabled = Boolean(settings.enabled && settings.activation_date);

  return <div className="accounting-journal-page">
    <header className="page-header">
      <div className="page-header-copy">
        <div className="page-eyebrow"><BookOpenText size={14}/><span>دفتر الأستاذ العام</span></div>
        <h2>القيود اليومية</h2>
        <p>إنشاء ومراجعة وترحيل القيود اليدوية والافتتاحية مع حماية التوازن وسجل كامل لتعديلات الماستر.</p>
      </div>
      <div className="accounting-head-actions">
        <button type="button" className="accounting-button ghost" onClick={load} disabled={state.loading}><RefreshCw size={15}/>تحديث</button>
        {canCreate && <button type="button" className="accounting-button primary" onClick={() => startEditor()}><CirclePlus size={16}/>قيد جديد</button>}
      </div>
    </header>

    <div className={"journal-readiness " + (postingEnabled ? "ready" : "disabled")}>
      <strong>{postingEnabled ? "الترحيل اليدوي مفعل" : "الترحيل غير مفعل بعد"}</strong>
      <span>{postingEnabled ? "تاريخ بدء المحاسبة: " + settings.activation_date : "يمكن تجهيز المسودات، لكن الترحيل يحتاج تفعيل المحاسبة وفترة مفتوحة من Owner."}</span>
      <span>الترحيل التلقائي من المبيعات والمشتريات والمخزون لم يُفعّل بعد.</span>
    </div>

    <section className="accounting-panel">
      <div className="accounting-toolbar">
        <label>من<input type="date" value={range.from} onChange={(event) => setRange((current) => ({ ...current, from: event.target.value }))}/></label>
        <label>إلى<input type="date" value={range.to} onChange={(event) => setRange((current) => ({ ...current, to: event.target.value }))}/></label>
      </div>

      {state.error && <div className="accounting-notice error" role="alert">{state.error}</div>}
      {state.success && <div className="accounting-notice success" role="status">{state.success}</div>}

      {state.loading ? <div className="accounting-empty">جارِ تحميل القيود...</div> :
        journals.length === 0 ? <div className="accounting-empty">لا توجد قيود في الفترة المحددة.</div> :
        <div className="journal-table-wrap"><table className="journal-table">
          <thead><tr><th>رقم القيد</th><th>التاريخ</th><th>البيان</th><th>النوع</th><th>الحالة</th><th>مدين</th><th>دائن</th><th>الإجراءات</th></tr></thead>
          <tbody>{journals.map((row) => {
            const isPeriodOpen = periodOpen(periods, row.entry_date);
            return <tr key={row.id}>
              <td><b>{row.entry_number}</b>{row.master_overridden && <small className="journal-master-tag">Master Override · Rev {row.revision_number}</small>}</td>
              <td>{row.entry_date}</td>
              <td>{row.description}<small>{row.reference || "—"}</small></td>
              <td>{ORIGIN_LABELS[row.entry_origin] || row.entry_origin}</td>
              <td><span className={"journal-status " + row.status}>{STATUS_LABELS[row.status] || row.status}</span></td>
              <td>{Number(row.total_debit || 0).toLocaleString("en-US", { minimumFractionDigits: 2 })}</td>
              <td>{Number(row.total_credit || 0).toLocaleString("en-US", { minimumFractionDigits: 2 })}</td>
              <td><div className="accounting-row-actions">
                {row.status === "draft" && canCreate && <button type="button" onClick={() => startEditor(row, "draft-edit")}><Pencil size={14}/>تعديل</button>}
                {row.status === "draft" && canPost && <button type="button" disabled={!postingEnabled || !isPeriodOpen || state.busy} onClick={() => post(row)}><Send size={14}/>ترحيل</button>}
                {row.status === "posted" && isOwner && <button type="button" disabled={!isPeriodOpen} onClick={() => startEditor(row, "owner-edit")}><Pencil size={14}/>تعديل الماستر</button>}
                {row.status === "posted" && canReverse && row.entry_origin !== "system" && row.entry_origin !== "reversal" &&
                  <button type="button" disabled={!postingEnabled || state.busy} onClick={() => setReversal({ row, date: today(), reason: "" })}><RotateCcw size={14}/>عكس</button>}
              </div></td>
            </tr>;
          })}</tbody>
        </table></div>}
    </section>

    {editor && <JournalEditor editor={editor} setEditor={setEditor} accounts={accounts} projects={projects} onClose={() => setEditor(null)} onSave={saveEditor} busy={state.busy} isOwner={isOwner}/>}

    {reversal && <div className="accounting-modal-layer" role="dialog" aria-modal="true" aria-label="عكس القيد">
      <div className="accounting-modal compact">
        <div className="accounting-modal-head">
          <div><span>قيد عكسي مستقل</span><h3>عكس {reversal.row.entry_number}</h3></div>
          <button type="button" className="accounting-close" onClick={() => setReversal(null)}>×</button>
        </div>
        <label>تاريخ العكس<input type="date" value={reversal.date} onChange={(event) => setReversal((current) => ({ ...current, date: event.target.value }))}/></label>
        <label>سبب العكس<textarea rows={4} value={reversal.reason} onChange={(event) => setReversal((current) => ({ ...current, reason: event.target.value }))}/></label>
        <div className="accounting-modal-actions">
          <button type="button" className="accounting-button ghost" onClick={() => setReversal(null)}>رجوع</button>
          <button type="button" className="accounting-button primary" disabled={state.busy} onClick={runReversal}>تأكيد العكس</button>
        </div>
      </div>
    </div>}
  </div>;
}

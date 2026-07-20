import React, { useEffect, useMemo, useState } from "react";
import { Bell, ChevronDown, LogOut, Menu, RefreshCw, Search, X, Zap } from "lucide-react";
import { supabase } from "../supabaseClient";

function Sidebar({ navigationGroups, openGroups, setOpenGroups, activeGroup, activeTab, profile, roleLabel, realtimeStatus, onNavigate, onSignOut, onClose }) {
  return <aside className="app-sidebar" aria-label="القائمة الجانبية">
    <button type="button" className="drawer-close" aria-label="إغلاق القائمة" onClick={onClose}><X size={20}/></button>
    <div className="sidebar-brand">
      <img src="/logo.png" alt="NEXTEP" />
      <div className="sidebar-user"><div className="sidebar-avatar">{(profile.full_name || profile.email || "N").trim().charAt(0)}</div><div className="sidebar-user-copy"><strong>{profile.full_name || profile.email}</strong><span>{roleLabel}</span></div></div>
      {import.meta.env.DEV && <div className="realtime-indicator"><span className={`realtime-dot ${realtimeStatus === "CONNECTED" ? "connected" : ""}`} />Realtime: {realtimeStatus}</div>}
    </div>
    <nav className="sidebar-nav" aria-label="التنقل الرئيسي">
      {navigationGroups.map((group) => { const isOpen = openGroups[group.id] !== false; return <section className={`nav-group ${isOpen ? "open" : ""} ${group.id === activeGroup?.id ? "active" : ""}`} key={group.id}>
        <button className="nav-group-toggle" type="button" aria-expanded={isOpen} onClick={() => setOpenGroups((current) => ({ ...current, [group.id]: !isOpen }))}><span>{group.label}</span><ChevronDown size={15} className={isOpen ? "open" : ""}/></button>
        {isOpen && <div className="nav-group-items"><div className="nav-group-items-inner">{group.items.map((item) => { const Icon = item.icon; const active = activeTab === item.id; return <button key={item.id} className={`nav-item ${active ? "active" : ""}`} aria-current={active ? "page" : undefined} onClick={() => onNavigate(item.id)}><Icon size={17}/><span>{item.label}</span></button>; })}</div></div>}
      </section>; })}
    </nav>
    <button type="button" className="sidebar-signout" onClick={onSignOut}><LogOut size={15}/>تسجيل الخروج</button>
  </aside>;
}

function Topbar({ activeGroup, activePage, navigationGroups, realtimeStatus, warnings, onNavigate, onMenu, onRetryData }) {
  const [search, setSearch] = useState("");
  const [searchResults, setSearchResults] = useState([]);
  const [searchBusy, setSearchBusy] = useState(false);
  const [notificationsOpen, setNotificationsOpen] = useState(false);
  const [actionItems, setActionItems] = useState([]);
  const [actionError, setActionError] = useState("");
  const allItems = useMemo(() => navigationGroups.flatMap((group) => group.items.map((item) => ({ ...item, group: group.label }))), [navigationGroups]);
  const pageResults = search.trim() ? allItems.filter((item) => item.label.includes(search.trim())).slice(0, 4) : [];
  const quickItems = ["projects", "production", "purchases", "team"].map((id) => allItems.find((item) => item.id === id)).filter(Boolean).slice(0, 3);
  const disconnected = !["CONNECTED", "DEMO"].includes(realtimeStatus);
  const notificationCount = actionItems.length + warnings.length + (disconnected ? 1 : 0);

  async function loadActions() {
    setActionError("");
    const { data, error } = await supabase.rpc("get_action_center", { limit_count: 30 });
    if (error) setActionError("تعذر تحميل التنبيهات الآن."); else setActionItems(data?.items || []);
  }

  useEffect(() => { void loadActions(); }, []);
  useEffect(() => {
    const q = search.trim();
    if (q.length < 2) { setSearchResults([]); setSearchBusy(false); return undefined; }
    setSearchBusy(true);
    const timer = window.setTimeout(async () => {
      const { data, error } = await supabase.rpc("search_workspace", { search_term: q, limit_count: 12 });
      setSearchResults(error ? [] : (data?.items || []));
      setSearchBusy(false);
    }, 250);
    return () => window.clearTimeout(timer);
  }, [search]);

  const go = (pageId) => { onNavigate(pageId); setSearch(""); setSearchResults([]); };
  return <header className="app-topbar">
    <div className="topbar-title-row"><button type="button" className="topbar-icon mobile-menu-button" aria-label="فتح القائمة" onClick={onMenu}><Menu size={21}/></button><div className="topbar-title"><div className="topbar-breadcrumb"><span>نظام NEXTEP</span><b>/</b><span>{activeGroup?.label || "الرئيسية"}</span></div><h1>{activePage?.label || "مساحة العمل"}</h1></div></div>
    <div className="topbar-tools">
      <div className="global-search"><Search size={17}/><input aria-label="البحث العام" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="مشروع، موظف، أصل، أمر شراء..."/>
        {(pageResults.length > 0 || searchResults.length > 0 || searchBusy) && <div className="global-search-results">
          {pageResults.map((item) => <button type="button" key={`page-${item.id}`} onClick={() => go(item.id)}><span>{item.label}</span><small>{item.group}</small></button>)}
          {searchResults.map((item) => <button type="button" key={`${item.kind}-${item.reference_id}`} onClick={() => go(item.page_id)}><span>{item.title}</span><small>{item.subtitle || item.kind}</small></button>)}
          {searchBusy && <p>جارِ البحث...</p>}
        </div>}
      </div>
      <div className="quick-actions" aria-label="إجراءات سريعة"><Zap size={15}/>{quickItems.map((item) => <button type="button" key={item.id} onClick={() => onNavigate(item.id)}>{item.label}</button>)}</div>
      <div className="notifications-wrap">
        <button type="button" className="topbar-icon" aria-label="الإشعارات" aria-expanded={notificationsOpen} onClick={() => { setNotificationsOpen((open) => !open); if (!notificationsOpen) void loadActions(); }}><Bell size={19}/>{notificationCount > 0 && <b>{notificationCount}</b>}</button>
        {notificationsOpen && <div className="notifications-panel"><strong>مركز المتابعة</strong>
          {!notificationCount && !actionError && <p className="notification-ok">لا توجد عناصر تحتاج تدخلاً حاليًا.</p>}
          {actionItems.map((item) => <button type="button" key={`${item.kind}-${item.reference_id}`} onClick={() => { onNavigate(item.page_id); setNotificationsOpen(false); }}><span>{item.title}</span><small>{item.detail}</small></button>)}
          {disconnected && <p>التحديث اللحظي: {realtimeStatus === "RECONNECTING" ? "جارِ إعادة الاتصال" : "جارِ الاتصال"}</p>}
          {warnings.length > 0 && <p>تعذر تحديث {warnings.length} من مصادر البيانات.</p>}
          {actionError && <p>{actionError}</p>}
          <button type="button" onClick={() => { onRetryData(); void loadActions(); }}><RefreshCw size={14}/>تحديث الكل</button>
        </div>}
      </div>
    </div>
  </header>;
}

export function AppShell({ children, navigationGroups, openGroups, setOpenGroups, activeGroup, activePage, activeTab, profile, roleLabel, realtimeStatus, warnings, onNavigate, onRetryData, onSignOut }) {
  const [drawerOpen, setDrawerOpen] = useState(false);
  const navigate = (pageId) => { onNavigate(pageId); setDrawerOpen(false); };
  return <div dir="rtl" className={`app-shell ${drawerOpen ? "drawer-open" : ""}`}><button type="button" className="drawer-backdrop" aria-label="إغلاق القائمة" onClick={() => setDrawerOpen(false)}/><Sidebar {...{ navigationGroups, openGroups, setOpenGroups, activeGroup, activeTab, profile, roleLabel, realtimeStatus }} onNavigate={navigate} onSignOut={onSignOut} onClose={() => setDrawerOpen(false)}/><main className="app-main"><Topbar {...{ activeGroup, activePage, navigationGroups, realtimeStatus, warnings }} onNavigate={navigate} onMenu={() => setDrawerOpen(true)} onRetryData={onRetryData}/><div className="app-content">{children}</div></main></div>;
}

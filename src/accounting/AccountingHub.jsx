import React, { useState } from "react";
import { BookOpenText, FolderTree, Settings2 } from "lucide-react";
import { AccountingWorkspace } from "./AccountingWorkspace";
import { AccountingJournalPanel } from "./AccountingJournalPanel";
import { AccountingSettingsPanel } from "./AccountingSettingsPanel";
import "./accountingHub.css";

export function AccountingHub({ profile, permissions, projects = [] }) {
  const [section, setSection] = useState("coa");
  const isOwner = profile?.role === "owner";
  const sections = [
    { id: "coa", label: "شجرة الحسابات", icon: FolderTree },
    { id: "journals", label: "القيود اليومية", icon: BookOpenText },
    ...(isOwner ? [{ id: "settings", label: "الإعدادات والفترات", icon: Settings2 }] : []),
  ];

  return <div className="accounting-hub">
    <nav className="accounting-hub-tabs" aria-label="أقسام المحاسبة">
      {sections.map(({ id, label, icon: Icon }) =>
        <button type="button" key={id} className={section === id ? "active" : ""} onClick={() => setSection(id)}>
          <Icon size={16}/><span>{label}</span>
        </button>
      )}
    </nav>
    {section === "coa" && <AccountingWorkspace profile={profile} permissions={permissions}/>}
    {section === "journals" && <AccountingJournalPanel profile={profile} permissions={permissions} projects={projects}/>}
    {section === "settings" && isOwner && <AccountingSettingsPanel profile={profile}/>}
  </div>;
}

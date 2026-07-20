import fs from 'node:fs';

function normalize(path, transforms) {
  let text = fs.readFileSync(path, 'utf8');
  for (const [pattern, replacement] of transforms) text = text.replace(pattern, replacement);
  fs.writeFileSync(path, text);
}

const escapeRegex = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

normalize('src/v22/shared.jsx', [
  [/(?:import \{ formatMoney, userFacingError \} from "\.\.\/userExperience";\r?\n)+/g, 'import { formatMoney, userFacingError } from "../userExperience";\n'],
]);

normalize('src/v22/projects.jsx', [
  [/(?:<div className="projects-result-count">عدد النتائج: <b>\{projects\.length\}<\/b><\/div>)+/g, '<div className="projects-result-count">عدد النتائج: <b>{projects.length}</b></div>'],
]);

const assignmentStatus = '<small className="table-sub">الرابط: {confirmationStatusLabel(a)}</small>';
const returnStatus = '<small className="table-sub">الرابط: {confirmationStatusLabel(r)}</small>';
const assignmentResend = '{a.status==="pending_receiver_confirmation"&&permissions.assets_issue&&<Button variant="ghost" onClick={()=>renewLink(a.id,"issue",a)}><ExternalLink size={14}/> إرسال/إعادة إرسال الرابط</Button>}';

normalize('src/assets/AssetsPage.jsx', [
  [new RegExp(`(?:${escapeRegex(assignmentStatus)})+`, 'g'), assignmentStatus],
  [new RegExp(`(?:${escapeRegex(returnStatus)})+`, 'g'), returnStatus],
  [new RegExp(`(?:${escapeRegex(assignmentResend)}){2,}`, 'g'), assignmentResend],
]);

normalize('src/v22/projectWorkspace.jsx', [
  [/(?:<details className="workspace-management"><summary>إدارة حالة المشروع والإنجاز<\/summary>)+<div className="workspace-actions-grid">/g, '<details className="workspace-management"><summary>إدارة حالة المشروع والإنجاز</summary><div className="workspace-actions-grid">'],
  [/<\/PermissionGuard><\/div>(?:<\/details>)+\s*<Panel><h3>آخر النشاط<\/h3>/g, '</PermissionGuard></div></details>\n       <Panel><h3>آخر النشاط</h3>'],
]);

console.log('[ux-normalize] completed');

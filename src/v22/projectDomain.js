export const PROJECT_EXECUTION_STAGES = Object.freeze({
  design: "التصميم",
  approval: "الاعتماد",
  manufacturing: "التصنيع",
  painting: "الدهان",
  installation: "التركيب",
  delivered: "تم التسليم",
  on_hold: "متوقف",
  cancelled: "ملغي",
});

export const PROJECT_LIFECYCLES = Object.freeze({
  draft: "مسودة",
  planning: "التخطيط",
  ready_for_activation: "جاهز للتفعيل",
  active: "نشط",
  on_hold: "متوقف مؤقتًا",
  completed: "مكتمل",
  closed: "مغلق",
  cancelled: "ملغي",
});

export const PROJECT_PRIORITIES = Object.freeze({ low: "منخفضة", normal: "عادية", high: "مرتفعة", urgent: "عاجلة" });
export const PROJECT_PROGRESS_MODES = Object.freeze({ manual: "يدوي", automatic: "تلقائي", hybrid: "هجين" });
export const MILESTONE_STATUSES = Object.freeze({ not_started: "لم تبدأ", in_progress: "جارية", blocked: "متعثرة", completed: "مكتملة", cancelled: "ملغاة" });
export const PROJECT_MEMBER_ROLES = Object.freeze({ project_manager: "مدير المشروع", site_engineer: "مهندس الموقع", designer: "مصمم", production: "الإنتاج", procurement: "المشتريات", accountant: "المحاسبة", viewer: "مشاهد" });

export const PROJECT_LIFECYCLE_TRANSITIONS = Object.freeze({
  draft: ["planning", "cancelled"],
  planning: ["draft", "ready_for_activation", "cancelled"],
  ready_for_activation: ["planning", "active", "cancelled"],
  active: ["on_hold", "completed"],
  on_hold: ["active", "cancelled"],
  completed: ["active", "closed"],
  closed: [],
  cancelled: [],
});

export function lifecycleTransitionsFor(lifecycle) {
  return PROJECT_LIFECYCLE_TRANSITIONS[lifecycle] || [];
}

export function lifecycleNeedsReason(from, to) {
  return to === "cancelled" || to === "closed" || (from === "completed" && to === "active");
}

export function calculatedMilestoneProgress(milestones = []) {
  const active = milestones.filter((milestone) => milestone.status !== "cancelled");
  const weight = active.reduce((sum, milestone) => sum + Number(milestone.weight_percentage || 0), 0);
  if (!weight) return 0;
  const weighted = active.reduce((sum, milestone) => sum + Number(milestone.weight_percentage || 0) * Number(milestone.progress_percentage || 0), 0);
  return Math.round((weighted / weight) * 100) / 100;
}

export function effectiveProjectProgress({ mode = "hybrid", manual = 0, calculated = 0, overrideReason = null }) {
  if (mode === "automatic") return Number(calculated || 0);
  if (mode === "manual") return Number(manual || 0);
  return overrideReason ? Number(manual || 0) : Number(calculated || 0);
}

export function projectWorkspaceSummary(project, data) {
  const byProject = (rows = []) => rows.filter((row) => row.project_id === project.id);
  const files = byProject(data.projectFiles);
  const activities = byProject(data.projectActivities);
  const milestones = byProject(data.projectMilestones);
  const members = byProject(data.projectMembers).filter((row) => row.active);
  const productionOrders = byProject(data.productionOrders);
  const labor = byProject(data.dailyLabor);
  const payroll = byProject(data.payroll);
  const expenses = byProject(data.expenses);
  const purchases = byProject(data.materialPurchases);
  const costs = byProject(data.projectCosts);
  const assignments = byProject(data.assetAssignments).filter((row) => ["pending_receiver_confirmation", "issued", "partially_returned", "settlement_pending"].includes(row.status));
  const overdueMilestones = milestones.filter((row) => row.status !== "completed" && row.status !== "cancelled" && row.planned_end_date && row.planned_end_date < new Date().toISOString().slice(0, 10));
  return { files, activities, milestones, members, productionOrders, labor, payroll, expenses, purchases, costs, assignments, overdueMilestones, blockers: milestones.filter((row) => row.status === "blocked") };
}

export function linkedProjectProfile(profiles, member) {
  return profiles.find((profile) => profile.id === member.profile_id) || null;
}


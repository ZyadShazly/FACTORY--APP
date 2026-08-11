const PAGE_PARAM = "page";
const PROJECT_PARAM = "project";

export function readWorkspaceLocation(search = "") {
  const params = new URLSearchParams(search);
  return {
    page: params.get(PAGE_PARAM) || null,
    projectId: params.get(PROJECT_PARAM) || null,
  };
}

export function workspaceUrl({ page, projectId }, currentHref = window.location.href) {
  const url = new URL(currentHref);
  if (page) url.searchParams.set(PAGE_PARAM, page); else url.searchParams.delete(PAGE_PARAM);
  if (page === "projects" && projectId) url.searchParams.set(PROJECT_PARAM, projectId);
  else url.searchParams.delete(PROJECT_PARAM);
  return `${url.pathname}${url.search}${url.hash}`;
}

export function safeProjectId(projectId, projects = []) {
  return projects.some((row) => row.id === projectId) ? projectId : null;
}

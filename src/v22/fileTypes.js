export const FILE_CATEGORIES = {
  "2d": "رسومات 2D", "3d": "تصميمات 3D", measurements: "المقاسات", cutting_list: "قوائم التقطيع",
  approvals: "الاعتمادات", site_photos: "صور الموقع", other: "أخرى",
};

export const SUPPORTED_FILE_EXTENSIONS = ["pdf", "jpg", "jpeg", "png", "webp", "dwg", "dxf", "xls", "xlsx", "doc", "docx", "zip"];
export const PROJECT_FILES_ACCEPT = SUPPORTED_FILE_EXTENSIONS.map((extension) => `.${extension}`).join(",");
export const isSupportedProjectFile = (fileName) => SUPPORTED_FILE_EXTENSIONS.includes(fileName.split(".").pop()?.toLowerCase());

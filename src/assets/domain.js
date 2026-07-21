export const ASSET_TYPES={tool:"عِدّة",equipment:"معدات",asset:"أصل",device:"جهاز",key:"مفتاح",vehicle:"مركبة (مستقبلي)",other:"أخرى"};
export const OPERATIONAL_STATUS={working:"يعمل",needs_maintenance:"يحتاج صيانة",under_maintenance:"تحت الصيانة",damaged:"تالف",lost:"مفقود",stolen:"مسروق",retired:"متقاعد"};
export const ASSIGNMENT_STATUS={draft:"مسودة",cancelled:"ملغاة",pending_receiver_confirmation:"بانتظار تأكيد المستلم",issued:"صادرة",partially_returned:"إرجاع جزئي",fully_returned:"أعيدت بالكامل",settlement_pending:"تسوية معلقة",closed:"مغلقة",reversed:"معكوسة"};
export const CONFIRMATION_METHOD_LABELS={authenticated_employee:"مؤكد بحساب الموظف",otp:"مؤكد برمز تحقق",bearer_link:"مؤكد عبر رابط غير موثّق بالهوية",admin_override:"تأكيد إداري استثنائي"};
export function outstanding(item){return Math.max(0,Number(item?.quantity||0)-Number(item?.returned_quantity||0)-Number(item?.settled_quantity||0))}
export function maskName(value=""){const [first,second]=value.trim().split(/\s+/);return second?`${first} ${second[0]}…`:first}
export function maskPhone(value=""){return value?`${"•".repeat(Math.max(value.length-2,0))}${value.slice(-2)}`:""}
export function normalizeInternationalPhone(value=""){let normalized=String(value||"").trim().replace(/[^0-9+]/g,"");if(normalized.startsWith("00"))normalized=`+${normalized.slice(2)}`;return /^\+[1-9][0-9]{7,14}$/.test(normalized)?normalized:""}
export function whatsappUrl(phone,message){const normalized=normalizeInternationalPhone(phone);return normalized?`https://wa.me/${normalized.slice(1)}?text=${encodeURIComponent(message)}`:""}
export function publicConfirmationBase(configuredUrl,currentOrigin,currentPath="/"){const configured=String(configuredUrl||"").trim();if(configured){try{return new URL(configured).toString()}catch{}}return new URL(currentPath||"/",currentOrigin).toString()}
export function buildConfirmationUrl(baseUrl,token,kind="issue"){const url=new URL(baseUrl);url.searchParams.set("assetConfirmation",token);url.searchParams.set("kind",kind);return url.toString()}
export function isPreviewConfirmationUrl(value){try{const host=new URL(value).hostname.toLowerCase();return host==="localhost"||host==="127.0.0.1"||host.endsWith(".vercel.app")}catch{return true}}
export function linkedProfileForEmployee(profiles,employeeId){return (profiles||[]).find(profile=>profile.employee_id===employeeId&&profile.status==="active")||null}
export function whatsappMessage({code,url,kind="issue",receiverName=""}){const greeting=receiverName?`السلام عليكم ${receiverName}،\n\n`:"السلام عليكم،\n\n";const action=kind==="return"?"مراجعة وتأكيد إرجاع العهدة":"مراجعة وتأكيد استلام العهدة";return `${greeting}لديك ${action} رقم ${code} على نظام NEXTEP.\n\nافتح الرابط التالي لمراجعة التفاصيل والتأكيد:\n${url}\n\nهذا الرابط مخصص لك، فلا تقم بإعادة إرساله لأي شخص.`}
export function canProductionAssetPermission(key){return ["assets_view","assets_issue","assets_return"].includes(key)}

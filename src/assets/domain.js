export const ASSET_TYPES={tool:"عِدّة",equipment:"معدات",asset:"أصل",device:"جهاز",key:"مفتاح",vehicle:"مركبة (مستقبلي)",other:"أخرى"};
export const OPERATIONAL_STATUS={working:"يعمل",needs_maintenance:"يحتاج صيانة",under_maintenance:"تحت الصيانة",damaged:"تالف",lost:"مفقود",stolen:"مسروق",retired:"متقاعد"};
export const ASSIGNMENT_STATUS={draft:"مسودة",cancelled:"ملغاة",pending_receiver_confirmation:"بانتظار تأكيد المستلم",issued:"صادرة",partially_returned:"إرجاع جزئي",fully_returned:"أعيدت بالكامل",settlement_pending:"تسوية معلقة",closed:"مغلقة",reversed:"معكوسة"};
export function outstanding(item){return Math.max(0,Number(item?.quantity||0)-Number(item?.returned_quantity||0)-Number(item?.settled_quantity||0))}
export function maskName(value=""){const [first,second]=value.trim().split(/\s+/);return second?`${first} ${second[0]}…`:first}
export function maskPhone(value=""){return value?`${"•".repeat(Math.max(value.length-2,0))}${value.slice(-2)}`:""}
export function buildConfirmationUrl(origin,token,kind="issue"){return `${origin}?assetConfirmation=${encodeURIComponent(token)}&kind=${kind}`}
export function whatsappMessage({code,url,kind="issue"}){return kind==="return"?`يرجى تأكيد بيانات إرجاع العهدة ${code}: ${url}`:`يرجى تأكيد استلام عهدة NEXTEP رقم ${code}: ${url}`}
export function canProductionAssetPermission(key){return ["assets_view","assets_issue","assets_return"].includes(key)}

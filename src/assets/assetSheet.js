// Excel-compatible UTF-8 CSV for the operational asset register.
// Import is intentionally not a general-ledger posting or depreciation workflow.
export const ASSET_SHEET_COLUMNS=["name","asset_type","tracking_mode","quantity","unit","category","location","brand","model","serial_number","purchase_date","purchase_cost","notes"];
const CSV_MAX_ROWS=500;
const CSV_MAX_CHARS=1000000;
function safeCell(value){
  const s=String(value??"");
  const guarded=/^[\s]*[=+@\-]/.test(s)?"'"+s:s;
  return '"'+guarded.replace(/"/g,'""')+'"';
}
export function assetSheetTemplate(){
 return "\uFEFF"+ASSET_SHEET_COLUMNS.map(safeCell).join(",")+"\r\n"+
 ["ماكينة تقطيع","machine","serialized","1","قطعة","","","", "", "", "2026-10-01","12000","مثال فقط - احذف هذا الصف قبل الاستيراد"].map(safeCell).join(",")+"\r\n";
}
export function exportAssetCsv(rows,categories=[],locations=[],includeCosts=false){
 const headers=["asset_code",...ASSET_SHEET_COLUMNS,"operational_status"];
 const lines=[headers.map(safeCell).join(",")];
 for(const a of rows){
  const record={...a,quantity:a.total_quantity,category:categories.find(c=>c.id===a.category_id)?.name||"",location:locations.find(l=>l.id===a.current_location_id)?.name||""};
  if(!includeCosts)record.purchase_cost="";
  lines.push(headers.map(key=>safeCell(record[key])).join(","));
 }
 return "\uFEFF"+lines.join("\r\n")+"\r\n";
}
export function parseAssetCsv(text){
 if(text.length>CSV_MAX_CHARS)throw new Error("الملف كبير جدًا. الحد الأقصى مليون حرف.");
 text=text.replace(/^\uFEFF/,"");
 let rows=[],row=[],field="",quoted=false;
 for(let i=0;i<text.length;i++){
  const ch=text[i];
  if(quoted){
   if(ch==='"'&&text[i+1]==='"'){field+='"';i++}
   else if(ch==='"')quoted=false;
   else field+=ch;
  }else if(ch==='"'&&field==="")quoted=true;
  else if(ch===","){row.push(field);field=""}
  else if(ch==="\n"||ch==="\r"){if(ch==="\r"&&text[i+1]==="\n")i++;row.push(field);if(row.some(v=>v.trim()))rows.push(row);row=[];field="";if(rows.length>CSV_MAX_ROWS+1)throw new Error("الحد الأقصى 500 أصل في الملف.")}
  else field+=ch;
 }
 if(quoted)throw new Error("تنسيق CSV غير صحيح: علامة اقتباس غير مغلقة.");
 row.push(field);if(row.some(v=>v.trim()))rows.push(row);
 if(rows.length<2)throw new Error("الملف لا يحتوي على أصول.");
 const columns=rows.shift().map(s=>s.trim());
 if(new Set(columns).size!==columns.length)throw new Error("عناوين الأعمدة مكررة.");
 for(const key of ["name","asset_type","tracking_mode","quantity"])if(!columns.includes(key))throw new Error("عمود مطلوب: "+key);
 const records=rows.map((values,index)=>{
  if(values.length!==columns.length)throw new Error("عدد الأعمدة غير صحيح في الصف "+(index+2));
  const a=Object.fromEntries(columns.map((key,i)=>[key,values[i]?.trim()||""]));
  if(!a.name||a.name.length>200)throw new Error("اسم الأصل مطلوب في الصف "+(index+2));
  if(!["tool","machine","equipment","vehicle","furniture","device","other"].includes(a.asset_type))throw new Error("نوع الأصل غير معروف في الصف "+(index+2)+": "+a.asset_type);
  if(!["serialized","quantity"].includes(a.tracking_mode))throw new Error("طريقة التتبع غير صحيحة في الصف "+(index+2));
  const qty=Number(a.quantity);
  if(!Number.isFinite(qty)||qty<=0||(a.tracking_mode==="serialized"&&qty!==1))throw new Error("كمية غير صالحة في الصف "+(index+2));
  if(a.purchase_cost&&(!Number.isFinite(Number(a.purchase_cost))||Number(a.purchase_cost)<0))throw new Error("تكلفة غير صالحة في الصف "+(index+2));
  if(a.purchase_date&&!/^\d{4}-\d{2}-\d{2}$/.test(a.purchase_date))throw new Error("تاريخ الشراء يجب أن يكون YYYY-MM-DD في الصف "+(index+2));
  return a;
 });
 return records;
}
export function downloadAssetCsv(name,content){
 const blob=new Blob([content],{type:"text/csv;charset=utf-8"});
 const url=URL.createObjectURL(blob);
 const a=document.createElement("a");a.href=url;a.download=name;document.body.appendChild(a);a.click();a.remove();
 setTimeout(()=>URL.revokeObjectURL(url),1000);
}

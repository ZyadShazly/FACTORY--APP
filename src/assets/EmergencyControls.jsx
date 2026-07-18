import React,{useState}from"react";
import{AlertTriangle,ShieldAlert}from"lucide-react";
import{Button,TextArea}from"../v22/shared";
import{CONFIRMATION_METHOD_LABELS}from"./domain";

export const EMERGENCY_ACTIONS={
 cancel_pending_assignment:{rpc:"cancel_pending_asset_assignment",title:"إلغاء إصدار معلّق وإعادة الكمية",effect:"سيتم تحرير الكمية المحجوزة بحركات Ledger عكسية، دون حذف سجل الإصدار.",success:"تم إلغاء الإصدار المعلّق وإعادة الكمية المتاحة."},
 reverse_issued_assignment:{rpc:"reverse_asset_assignment",title:"عكس عهدة صادرة وإعادة الرصيد",effect:"سيتم إنشاء حركات تعويضية كاملة. لا يمكن التنفيذ بعد إرجاع أو تسوية لاحقة.",success:"تم عكس العهدة الصادرة بحركات تعويضية."},
 cancel_pending_return:{rpc:"cancel_pending_asset_return",title:"إلغاء طلب الإرجاع دون تعديل الرصيد",effect:"لن تزيد الكمية المتاحة ولن يُسجل أن الأصل عاد فعليًا.",success:"تم إلغاء طلب الإرجاع دون تغيير الرصيد."},
 force_confirm_return:{rpc:"force_confirm_asset_return",title:"تأكيد استلام فعلي استثنائي",effect:"سيُطبق أثر الإرجاع الفعلي على الرصيد والـLedger باسم مالك النظام.",success:"تم تأكيد الاستلام الفعلي استثنائيًا."},
};

export function ConfirmationBadge({method}){if(!method)return null;return <span className={`confirmation-method ${method}`}>{CONFIRMATION_METHOD_LABELS[method]||method}</span>}

export function AssignmentEmergencyActions({assignment,quantity,onSelect}){return <div className="emergency-actions">
 {assignment.status==="pending_receiver_confirmation"&&<Button variant="danger" onClick={()=>onSelect({type:"cancel_pending_assignment",targetId:assignment.id,quantity})}>إلغاء إصدار معلّق وإعادة الكمية</Button>}
 {assignment.status==="issued"&&<Button variant="danger" onClick={()=>onSelect({type:"reverse_issued_assignment",targetId:assignment.id,quantity})}>عكس عهدة صادرة وإعادة الرصيد</Button>}
 </div>}

export function ReturnEmergencyActions({event,quantity,onSelect}){if(event.status!=="pending_receiver_confirmation")return null;return <div className="emergency-actions">
 <Button variant="ghost" onClick={()=>onSelect({type:"cancel_pending_return",targetId:event.id,quantity})}>إلغاء طلب الإرجاع دون تعديل الرصيد</Button>
 <Button variant="danger" onClick={()=>onSelect({type:"force_confirm_return",targetId:event.id,quantity})}>تأكيد استلام فعلي استثنائي</Button>
 </div>}

export function EmergencyActionModal({action,busy,onConfirm,onClose}){const [reason,setReason]=useState(""),[physicalVerified,setPhysicalVerified]=useState(false);if(!action)return null;const config=EMERGENCY_ACTIONS[action.type],requiresPhysical=action.type==="force_confirm_return";return <div className="v22-modal-backdrop"><form className="v22-modal emergency-modal" onSubmit={e=>{e.preventDefault();onConfirm({...action,reason:reason.trim(),physicalVerified})}}><ShieldAlert size={30}/><h3>{config.title}</h3><div className="emergency-impact"><AlertTriangle size={18}/><div><b>الكمية المتأثرة: {action.quantity}</b><p>{config.effect}</p></div></div><label>سبب الإجراء الاستثنائي</label><TextArea required value={reason} onChange={e=>setReason(e.target.value)} placeholder="اكتب سببًا واضحًا قابلًا للمراجعة في سجل التدقيق"/>{requiresPhysical&&<label className="physical-check"><input required type="checkbox" checked={physicalVerified} onChange={e=>setPhysicalVerified(e.target.checked)}/> أؤكد أنني تحققت من الاستلام الفعلي للكمية الموضحة</label>}<div className="v22-actions"><Button type="button" variant="ghost" onClick={onClose}>رجوع دون تنفيذ</Button><Button variant="danger" disabled={busy||!reason.trim()||(requiresPhysical&&!physicalVerified)}>تنفيذ الإجراء الموثق</Button></div></form></div>}

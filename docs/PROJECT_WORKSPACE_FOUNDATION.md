# Project Workspace Foundation

## النطاق

هذه ترقية داخلية لوحدة المشاريع الحالية وليست إعادة بناء. تم الحفاظ على سجلات
`projects` ومعرفاتها وأكوادها وعلاقات العملاء والملفات ومسارات Storage والأنشطة
و`project_costs` وروابط المصروفات والعمالة والرواتب والإنتاج والمشتريات والأصول.

## ما تم الحفاظ عليه وتمديده

- **محفوظ:** قائمة المشاريع والبحث والفلاتر، `project_code` و`project_name`،
  `project_files` و`project_activities` و`project_costs`، و`get_projects_visible`.
- **ممتد:** `projects` بدورة حياة مستقلة، نموذج إنجاز قابل للتفسير، أولوية،
  ومسار توافق لـ`status`.
- **جديد ومطبع:** `project_milestones` و`project_members` وإشارة Realtime آمنة.
- **مستبدل:** الكتابة المباشرة على `projects` بـRPCs محمية. زر الحذف النهائي
  استُبدل بإلغاء موثق عبر دورة الحياة.
- **مهمل للتوافق فقط:** `projects.status`؛ يظل موجودًا ومتزامنًا مع
  `execution_stage` حتى لا تنكسر التكاملات القديمة.

## ترحيل الحالة القديمة

| `status` القديم | `execution_stage` | `lifecycle` الجديد |
|---|---|---|
| design | design | planning |
| approval | approval | planning |
| manufacturing | manufacturing | active |
| painting | painting | active |
| installation | installation | active |
| delivered | delivered | completed |
| on_hold | on_hold | on_hold |
| cancelled | cancelled | cancelled |

لا يتحول `delivered` إلى `closed`. جميع المشاريع الموجودة وقت الترحيل تحصل على
`legacy_activation_exempt=true` حتى لا يوقفها شرط ميزانية لم يكن موجودًا عند
تشغيلها. المشاريع الجديدة تبدأ `draft` وبدون إعفاء.

## انتقالات دورة الحياة

- `draft → planning | cancelled`
- `planning → draft | ready_for_activation | cancelled`
- `ready_for_activation → planning | active | cancelled`
- `active → on_hold | completed`
- `on_hold → active | cancelled`
- `completed → closed`، أو `active` بواسطة Owner فقط مع سبب.
- `closed` و`cancelled` نهائيتان.

الإلغاء والإغلاق وإعادة فتح المكتمل تتطلب سببًا. الانتقالات تقفل صف المشروع
وتتحقق داخل قاعدة البيانات، ولا تعتمد على خيارات الواجهة.

## جاهزية التفعيل

`project_activation_readiness` يعيد checks مسماة للبيانات الأساسية والتواريخ
ومدير المشروع. فحص `estimated_budget_approval` موجود كعقد توسعة فقط وحالته
`not_implemented` وغير حاجب في هذا Sprint. لا توجد ميزانية تقديرية أو اعتماد
وهمي.

## نموذج الإنجاز

- `manual`: الفعلي يساوي اليدوي.
- `automatic`: الفعلي يساوي المتوسط الموزون للمراحل النشطة.
- `hybrid`: المحسوب هو الاقتراح، ولا يبقى التجاوز اليدوي مختلفًا دون سبب موثق.
- المرحلة الملغاة مستبعدة، المكتملة 100%، والتي لم تبدأ 0%، والمتعثرة تحتفظ
  بإنجازها.
- مجموع أوزان المراحل النشطة لا يتجاوز 100% بحظر Database Trigger.
- `progress_percentage` محفوظ كتوافق ويعكس `effective_progress_percentage`.
- الإنفاق واستهلاك الميزانية لا يدخلان في الإنجاز المادي.

## العضوية والرؤية

`project_members` يقبل Profile أو Employee أو كليهما بشرط العلاقة المعيارية
`profiles.employee_id → employees.id`. توجد عضوية نشطة واحدة لكل هوية في
المشروع، ومدير مشروع نشط واحد. `project_manager_id` يتحدث فقط من RPCs الفريق.

Owner وManager يريان كل المشاريع. Accountant يحتاج `projects_view`. غير الإداري
يرى المشروع من عضوية نشطة، ولا تمنحه العضوية أي صلاحية نظام عامة. الحقول المالية
لا ترجع من `get_projects_visible` إلا مع `project_financials_view`.

## مصدر حقيقة التكلفة ومنع الازدواج

المصدر الحالي هو `project_costs` مع `refresh_project_actual_cost` و
`sync_project_cost`. مفتاح منع الازدواج المستقبلي يجب أن يكون مركبًا من
`source_type + source_id + allocation_revision`، لا من الوصف أو التاريخ.

- **شراء ومخزون:** التكلفة عند الاستهلاك/الصرف للمشروع، لا عند الشراء ثم
  الاستهلاك معًا.
- **رواتب وعمالة مصنع:** إما قيد Payroll allocation أو قيد تخصيص المصنع، لا
  الاثنان لنفس الموظف والفترة والمشروع.
- **مصروفات وعهد نقدية:** قيد المصروف المعتمد أو تسوية العهدة، لا كليهما.
- **الأصول:** عهدة الأصل ليست تكلفة. التكلفة المستقبلية تحتاج استخدامًا معتمدًا
  أو إهلاكًا أو إيجارًا أو وقودًا أو تشغيلًا.

الأنواع المستقبلية الموثقة: `factory_employee_labor`, `asset_usage`,
`petty_cash`, `employee_cash_custody`, `subcontractor`, `rental_equipment`.
لم تُضف إلى check الحالي قبل وجود Ledger ومفاتيح dedup الفعلية.

## تخصيص موظفي المصنع — Extension Contract

التنفيذ المستقبلي يدعم `days | hours | percentage` مع Calendar version، الغياب
غير المدفوع، الإضافي، اليوم الجزئي، وتعدد المشاريع في اليوم. عقد التخصيص يجب أن
يحمل employee، payroll period، project، method، quantity، calendar snapshot،
source payroll revision، وdedup key. لم يُنفذ حساب شهري أو خصم أو قيد تكلفة في
هذا Sprint.

## Realtime والأمان

`projects` لا يُقرأ مباشرةً بسبب الحقول المالية؛ `project_realtime_signal`
يطلب إعادة `get_projects_visible`. المراحل والأعضاء يخضعان لـRLS المشروع، وتضاف
الجداول الثلاثة إلى `supabase_realtime` دون تكرار. العميل يستخدم القناة المركزية
القائمة ويعمل targeted refetch بلا Reload.

كل Business RPC يثبت `search_path` ويتحقق من `auth.uid()` وProfile نشط وصلاحية
دقيقة وعضوية الإدارة عند الحاجة. Trigger/helpers الداخلية مسحوب منها EXECUTE
لـ`PUBLIC`, `anon`, و`authenticated`. `anon` لا يملك أي وصول للمشاريع.

## خارج النطاق

Quotations، Estimated Budget الكاملة، Actual Cost allocation المتقدمة، MRP، GL،
AR، AP، Petty Cash، Cash Custody، forecast، profitability analysis، ومحرك توزيع
رواتب المصنع لم تُنفذ في هذا PR.


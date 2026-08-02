# NEXTEP Factory ERP

واجهة عربية RTL لإدارة عمليات المصنع، مبنية باستخدام React وSupabase.

## الحالة الحالية

المرجع التشغيلي الحالي هو
[Current System Status](docs/CURRENT_SYSTEM_STATUS.md). يجمع حالة `main`،
GitHub، Supabase الحي، عقود الوحدات، خريطة migrations، وخطة التنفيذ المعتمدة.

خطة Full Pilot القديمة ذات المراحل 0–15 وملف التتبع المرتبط بها محفوظان كسجل
تاريخي فقط. المراحل 0–7 مدمجة بالفعل، ولا يجوز استخدام حالات الـDraft القديمة
كأوامر تنفيذ أو كدليل على حالة GitHub الحالية.

## التشغيل المحلي

```bash
npm ci
npm run dev
```

يتطلب التشغيل ملف `.env.local` بالقيم التالية:

```text
VITE_SUPABASE_URL=...
VITE_SUPABASE_ANON_KEY=...
```

لا تضف بريدًا أو UUID أو كلمة مرور أو `service_role` إلى GitHub أو متغيرات
`VITE_`. اتبع [دليل الهوية والأمان](docs/IDENTITY_SECURITY.md) لإجراءات
الهوية والترقية الآمنة.

## Supabase migrations

ملفات `supabase/migrations` هي التاريخ القابل للمراجعة للمستودع، وأحدث ملف
حاليًا هو:

```text
202607290003_explicit_inventory_item_type.sql
```

لا تفترض أن غياب رقم ملف محلي من سجل Supabase يعني أن الـmigration غير مطبقة.
البيئة الحية تحتوي migrations طُبقت بأرقام توليد مختلفة، كما تحتوي بعض العقود
الحية التي لا يظهر لها اسم ملف مطابق في سجل migrations. راجع خريطة
repository-to-live في
[Current System Status](docs/CURRENT_SYSTEM_STATUS.md) قبل إعداد أي migration
جديدة.

أي تغيير schema جديد يجب أن:

- يكون additive أو له مسار استعادة واضح؛
- يراجع مقابل schema الحي أولًا؛
- يحدد `GRANT` و`REVOKE` المقصودين صراحةً؛
- لا يطبق على Supabase الحي ضمن PR عادي؛
- يتبعه فحص RLS والصلاحيات والـRPCs وSupabase Advisors.

بعد أي تطبيق معتمد، تحقق من عضوية جداول Realtime باستخدام
[دليل Multi-user Realtime](docs/multi-user-realtime.md).

## العقود الحالية المهمة

- `inventory_items.item_type` هو المصدر الرسمي الوحيد لتصنيف صنف المخزون إلى
  `raw_material` أو `finished_good`. لا تضف عقدًا موازيًا باسم `stock_kind`.
- سجلات Inventory وProduction وActual Cost المحمية تستخدم RPCs والـledgers
  الحالية، وليس direct client mutations.
- Cash Custody نفسها ليست مصروفًا؛ فقط settlement line معتمدة يمكن أن تصبح
  Actual Cost وفق العقد الموثق.

## التحقق قبل النشر

```bash
npm test
npm run build
git diff --check
node scripts/assert-clean-working-tree.mjs
```

يلزم كذلك نجاح GitHub Quality Gate وVercel، واختبار Desktop/Mobile RTL المناسب
لنطاق التغيير.

### اختبار حماية الأدوار عبر API مباشر

اختبار `tests/security-role-creation.test.mjs` يتحقق دائمًا من عقد الـMigration.
ويمكنه أيضًا تنفيذ محاولة REST حقيقية على مشروع Supabase **تجريبي فقط** عند
ضبط المتغيرات التالية:

```text
SUPABASE_SECURITY_TEST_CONFIRM=true
SUPABASE_SECURITY_TEST_URL=...
SUPABASE_SECURITY_TEST_ANON_KEY=...
SUPABASE_SECURITY_TEST_SERVICE_ROLE_KEY=...
```

لا تضبط هذه القيم على Production. بدونها يُتخطى اختبار التكامل الحي وتستمر
اختبارات العقد المحلية.


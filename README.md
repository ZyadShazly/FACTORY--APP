# NEXTEP Factory ERP

واجهة عربية RTL لإدارة عمليات المصنع، مبنية باستخدام React وSupabase.

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

## Supabase migrations

نفّذ ملفات `supabase/migrations` بالترتيب التصاعدي للاسم من خلال Supabase SQL Editor أو Supabase CLI. آخر migration حاليًا هو:

```text
202607160001_enforce_owner_manager_hierarchy.sql
```

نفّذ migrations بالترتيب حتى `202607150003_owner_identity_security.sql`، ثم نفّذ `202607160001_enforce_owner_manager_hierarchy.sql` أخيرًا. يضيف التسلسل دور مالك النظام، ويجعل Owner وحده قادرًا على إدارة Manager، ويقصر Manager على إدارة Accountant وProduction عبر RPC مدققة.

بعد مراجعة PR وتطبيق الـMigration، اتبع [دليل الهوية والأمان](docs/IDENTITY_SECURITY.md) لتشغيل سكربت الترقية الآمن لحساب موجود. لا تضف بريدًا أو UUID أو كلمة مرور أو `service_role` إلى GitHub أو متغيرات `VITE_`.

بعد تنفيذ migrations، تحقّق من إضافة الجداول المطلوبة إلى `supabase_realtime` باستخدام الاستعلام الموجود في `docs/multi-user-realtime.md`.

## التحقق قبل النشر

```bash
npm test
npm run build
```

سيناريو الاختبار اليدوي متعدد المستخدمين موثق في `docs/multi-user-realtime.md`.

### اختبار حماية الأدوار عبر API مباشر

اختبار `tests/security-role-creation.test.mjs` يتحقق دائمًا من عقد الـMigration. ويمكنه أيضًا تنفيذ محاولة REST حقيقية على مشروع Supabase **تجريبي فقط** مع حذف مستخدم الاختبار تلقائيًا عند ضبط المتغيرات التالية:

```text
SUPABASE_SECURITY_TEST_CONFIRM=true
SUPABASE_SECURITY_TEST_URL=...
SUPABASE_SECURITY_TEST_ANON_KEY=...
SUPABASE_SECURITY_TEST_SERVICE_ROLE_KEY=...
```

لا تضبط هذه القيم على Production. بدونها يُتخطى اختبار التكامل الحي وتستمر اختبارات العقد المحلية.


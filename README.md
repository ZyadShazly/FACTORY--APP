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

نفّذ ملفات `supabase/migrations` بالترتيب التصاعدي للاسم من خلال Supabase SQL Editor أو Supabase CLI. آخر migration خاص بمراجعة الاستقرار هو:

```text
202607150001_stabilize_production_access.sql
```

هذا الملف يثبت أن موظف الإنتاج يصل إلى أوامر الإنتاج فقط، ويلغي صلاحيات المشاريع والملفات القديمة، ويضيف RLS تقييدية للوحدات المالية والإدارية.

بعد تنفيذ migrations، تحقّق من إضافة الجداول المطلوبة إلى `supabase_realtime` باستخدام الاستعلام الموجود في `docs/multi-user-realtime.md`.

## التحقق قبل النشر

```bash
npm test
npm run build
```

سيناريو الاختبار اليدوي متعدد المستخدمين موثق في `docs/multi-user-realtime.md`.


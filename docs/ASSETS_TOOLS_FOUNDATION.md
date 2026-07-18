# Assets & Tools Management — Phase 1

## النطاق

توفر المرحلة سجل الأصول والتصنيفات والمواقع وإصدار العهد وتأكيدها والإرجاع الجزئي والكامل وتسوية الفقد أو التلف وسجل حركة غير قابل للتعديل. لا تشمل الصيانة المتقدمة أو السيارات أو الإهلاك أو تكامل WhatsApp المدفوع.

## مصدر الحقيقة

`asset_movements` هو مصدر حقيقة الرصيد. حقول `total_quantity` و`available_quantity` و`assigned_quantity` داخل `assets` أرصدة Cached للأداء فقط، وتحدثها Trigger في نفس معاملة الحركة. تعرض `asset_balance_reconciliation()` مقارنة Ledger بالأرصدة المخزنة لاكتشاف أي انحراف دوريًا.

## نموذج الأصل

- `serialized`: سجل لكل قطعة؛ الكمية 1، وSerial/QR فريدان عند وجودهما، وعهدة نشطة واحدة فقط.
- `quantity`: سجل لصنف كمي يدعم الإصدار والإرجاع الجزئي.
- لا يتغير `tracking_mode` بعد أول حركة.
- لا تخفض الكمية عن الرصيد المعين أو المعلق؛ التخفيض Adjustment Ledger موثق فقط.

## دورة العهدة

`draft → pending_receiver_confirmation → issued → partially_returned → fully_returned → closed`

- تلغى `draft` مباشرة.
- بعد الحجز أو الإصدار لا يوجد انتقال إلى `cancelled`. الاسترجاع الإداري الطارئ يتم عبر `reverse_asset_assignment` وحركات `reversed` كاملة.
- كل إصدار يقفل صف الأصل ويتحقق من الرصيد والحالة التشغيلية قبل الحركة.

## الإرجاع والتسويات

يمكن إنشاء عدة Return Events، ولا تتجاوز مجموعاتها المتبقي. لا تعود الكمية إلى المتاح قبل تأكيد المستلم الأصلي. الكمية التالفة لا تصبح متاحة. الفقد والسرقة والتلف والشطب تحتاج تسوية، وAccountant لا يعتمد تسوية أنشأها بنفسه.

## التأكيد الخارجي

- Token عشوائي، ولا يخزن سوى SHA-256 hash.
- الرابط مؤقت ولمرة واحدة، ويعرض صفحة منتهية بعد الاستخدام أو الانتهاء.
- الاسم والهاتف مقنعان، ولا تعرض التكلفة أو روابط التنقل.
- خمس محاولات فاشلة تقفل الرابط 15 دقيقة.
- المرحلة الحالية توفر Copy Message و`wa.me`؛ Provider/Webhook الفعلي مؤجل.

## الصلاحيات

Owner وManager تلقائيًا. Accountant حسب المنح. Production يمكن منحه فقط `assets_view` و`assets_issue` و`assets_return`. حقول الشراء والمورد لا تعاد إلا للإدارة أو حامل `assets_reports`. كل Business Mutation تمر عبر RPC محمية، بينما رفع المرفقات له RLS محدودة على bucket خاص.

## التنبيهات

`asset_alerts` View مشتقة للعهد المتأخرة، التأكيد المعلق، الضمان القريب، والمفقود/المسروق/تحت الصيانة. تتحدث الواجهة عند أي Realtime change في جداول Assets.

## QR Contract

`qr_value` معرف فريد وليس تفويضًا. المسح يفتح `?assetQr=<value>`، وبعد تسجيل الدخول تطبق `assets_view` وتظهر الأوامر حسب الصلاحية. الأصل الكمي يطلب الكمية عند الإصدار.

## Migration

بعد `202607180002_payroll_calendar_foundation.sql` طبّق:

`202607180003_assets_tools_foundation.sql`

إذا كانت Migration السابقة مطبقة بالفعل، طبّق بعدها مباشرة:

`202607180004_fix_assets_pgcrypto_schema.sql`

الـHotfix يؤهل وظائف `pgcrypto` صراحةً داخل schema `extensions`، ويعيد إنشاء RPCs المتأثرة ويصلح Stored Defaults دون إعادة إنشاء الجداول.

ثم تحقق من `asset_balance_reconciliation()`، ومن وجود bucket الخاص `asset-attachments` وسياسات Realtime/RLS.

## قبول التشغيل

اختبر بحسابين: إصدار أصل فردي، أصل كمي جزئي، تأكيد الاستلام، إرجاعين جزئيين، إرجاع كامل، تسوية فقد وسرقة، maker-checker، Realtime، QR، رابط منتهي، Rate Limit، Offline/Retry، وProduction دون حقول مالية. شغّل `npm test` و`npm run build` واختبار RTL على Desktop و375px.

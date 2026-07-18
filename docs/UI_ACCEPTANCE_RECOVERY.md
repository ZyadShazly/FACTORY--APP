# UI Acceptance & Recovery Pass

## النطاق

هذه المهمة Pass محدودة قبل Payroll V2.3. لا تغيّر الهوية البصرية أو وظائف الوحدات، وإنما تغلق مخاطر التعليق، الاسترداد، التنقل على الهاتف، وحالات الاتصال.

## Account bootstrap

- التحقق من الجلسة والـProfile له مهلة 12 ثانية.
- الحالات الصريحة: checking session، loading profile، ready، missing profile، error، signed out.
- الحساب الموجود في Auth بدون Profile يرى «فشل إعداد الحساب» ومعرّف حسابه، مع Retry وSign out.
- الإصلاح الإداري يتم من الإدارة ← الإعدادات بواسطة `admin_repair_missing_profile`.
- الـRPC يقبل Owner/Manager نشطًا فقط، ويتحقق من وجود `auth.users` وغياب `profiles`، وينشئ دور Accountant أو Production فقط بصلاحيات فارغة وحالة active.
- لا تتغير كلمة المرور، لا يُستخدم `service_role` في الواجهة، ولا يتم تعطيل أي Trigger. تُسجل العملية في Audit Log.

## Information Architecture decision

وُضع **Customers** و**Rentals** داخل مجموعة **المالية** لأنهما جزء من دورة العميل والإيراد والتحصيل، ويرتبطان مباشرة بالمبيعات والأرصدة. تظل **إدارة المشاريع** مخصصة لتنفيذ المشروع وملفاته، وتظل **التشغيل والإنتاج** مخصصة للمخزون والتصنيع. هذا يقلل التداخل دون إنشاء مجموعة جديدة أو إعادة تصميم الـIA.

## UI states contract

| الحالة | السلوك الموحد |
|---|---|
| Loading | مؤشر وحالة نصية، مع Timeout لمسار Bootstrap والتحميل الشبكي |
| Empty | رسالة فارغة داخل الوحدة الحالية |
| Error | رسالة مرئية باسم مصادر البيانات المتأثرة وزر Retry |
| Success | Toast بعد اكتمال mutation وrefetch |
| No Permission | حالة مستقلة بدل مساحة فارغة |
| Offline / Reconnecting | Banner مرئي، حالة في الإشعارات، وإعادة مزامنة تلقائية عند الاتصال |

## Acceptance scenarios

1. Desktop: Sidebar ثابت، Topbar موحدة، البحث والتنبيهات والإجراءات السريعة لا تغطي المحتوى.
2. Mobile 375px: Sidebar Drawer مغلق افتراضيًا، يفتح من Menu ويغلق بعد اختيار الصفحة أو الضغط خارج القائمة.
3. Owner/Manager: تظهر Settings وأداة استرداد الحساب.
4. Accountant/Production: لا تظهر Settings، وتظل الصفحات محكومة بالصلاحيات الحالية.
5. Auth بدون Profile: تظهر Account Setup Failed خلال حد أقصى 12 ثانية، وليس Loading دائمًا.
6. انقطاع Supabase: تظهر Error أو Reconnecting مع Retry، ثم تحدث المصالحة عند عودة الاتصال.

## Migration order

بعد آخر Migration مدمجة، نفّذ:

1. `202607180001_account_bootstrap_recovery.sql`

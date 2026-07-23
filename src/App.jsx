import React, { Suspense, lazy } from "react";

const AppMonolith = lazy(() => import("./AppMonolith.jsx"));

function AppLoadingFallback() {
  return (
    <div className="app-bootstrap-screen" dir="rtl" role="status" aria-live="polite">
      <div className="app-bootstrap-card">
        <strong>جاري تحميل NextEP...</strong>
        <span>يتم تجهيز وحدات النظام المطلوبة.</span>
      </div>
    </div>
  );
}

export default function App() {
  return (
    <Suspense fallback={<AppLoadingFallback />}>
      <AppMonolith />
    </Suspense>
  );
}

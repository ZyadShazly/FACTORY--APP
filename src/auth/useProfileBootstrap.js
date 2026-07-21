import { useCallback, useEffect, useRef, useState } from "react";
import { bootstrapErrorMessage, withTimeout } from "../bootstrap";
import { isActiveProfile } from "../realtime";

export function useProfileBootstrap({ supabase, demo = false, demoProfile = null }) {
  const [session, setSession] = useState(demo ? { user: { id: demoProfile.id } } : undefined);
  const [profile, setProfile] = useState(demo ? demoProfile : undefined);
  const [status, setStatus] = useState(demo ? "ready" : "checking-session");
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [sessionAttempt, setSessionAttempt] = useState(0);
  const profileRequest = useRef(0);

  const signOut = useCallback(async (message = "") => {
    if (message) setNotice(message);
    profileRequest.current += 1;
    setProfile(null);
    setSession(null);
    setStatus("signed-out");
    setError("");
    if (!demo) {
      const result = await supabase.auth.signOut({ scope: "local" });
      if (result.error) console.error("[Bootstrap] sign out failed", result.error);
    }
  }, [demo, supabase]);

  const fetchProfile = useCallback(async (userId, { background = false } = {}) => {
    if (demo) return { data: demoProfile, error: null };
    if (!userId) {
      const missingIdError = new Error("لم يتم العثور على معرّف المستخدم في الجلسة");
      setStatus("error");
      setError(missingIdError.message);
      return { data: null, error: missingIdError };
    }

    const requestId = ++profileRequest.current;
    if (!background) {
      setStatus("loading-profile");
      setError("");
    }
    try {
      let fetchResult = await withTimeout(
        supabase.from("profiles").select("*").eq("id", userId).maybeSingle(),
        undefined,
        "استغرق تحميل بيانات الحساب وقتًا أطول من المتوقع"
      );
      if (requestId !== profileRequest.current) return fetchResult;
      if (fetchResult.error) throw fetchResult.error;

      if (!fetchResult.data) {
        const recoveryResult = await withTimeout(
          supabase.rpc("complete_my_profile"),
          undefined,
          "استغرق استكمال ملف الحساب وقتًا أطول من المتوقع"
        );
        if (!recoveryResult.error && recoveryResult.data) {
          fetchResult = { data: recoveryResult.data, error: null };
        } else {
          console.error("[Bootstrap] authenticated user has no profile", { userId, recoveryError: recoveryResult.error });
          setProfile(null);
          setStatus("missing-profile");
          setError("تم تسجيل الدخول، لكن تعذر استكمال ملف الحساب. تواصل مع مدير النظام.");
          return recoveryResult;
        }
      }

      if (!isActiveProfile(fetchResult.data)) {
        console.warn("[Bootstrap] account suspended", { userId, status: fetchResult.data.status });
        await signOut("تم إيقاف حسابك. تواصل مع مدير النظام لإعادة تفعيله.");
        return fetchResult;
      }

      setProfile(fetchResult.data);
      setStatus("ready");
      setError("");
      return fetchResult;
    } catch (profileError) {
      if (requestId !== profileRequest.current) return { data: null, error: profileError };
      console.error("[Bootstrap] profile load failed", { userId, error: profileError });
      if (!background) {
        setProfile(undefined);
        setStatus("error");
        setError(bootstrapErrorMessage(profileError, "تعذر تحميل بيانات الحساب"));
      }
      return { data: null, error: profileError };
    }
  }, [demo, demoProfile, signOut, supabase]);

  useEffect(() => {
    if (demo) return undefined;
    let disposed = false;
    setStatus("checking-session");
    setError("");
    void (async () => {
      try {
        const result = await withTimeout(
          supabase.auth.getSession(),
          undefined,
          "استغرق التحقق من جلسة المستخدم وقتًا أطول من المتوقع"
        );
        if (disposed) return;
        if (result.error) throw result.error;
        setSession(result.data.session);
        if (!result.data.session) setStatus("signed-out");
      } catch (sessionError) {
        if (disposed) return;
        console.error("[Bootstrap] session check failed", sessionError);
        setStatus("error");
        setError(bootstrapErrorMessage(sessionError, "تعذر التحقق من جلسة المستخدم"));
      }
    })();
    return () => { disposed = true; };
  }, [demo, sessionAttempt, supabase]);

  useEffect(() => {
    if (demo) return undefined;
    const { data } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      setSession(nextSession);
      if (!nextSession) {
        profileRequest.current += 1;
        setProfile(null);
        setStatus("signed-out");
      }
    });
    return () => data.subscription.unsubscribe();
  }, [demo, supabase]);

  useEffect(() => {
    if (demo || session === undefined) return;
    if (!session) return;
    setNotice("");
    setProfile((current) => current?.id === session.user.id ? current : undefined);
    void fetchProfile(session.user.id);
  }, [demo, fetchProfile, session?.user?.id]);

  const retry = useCallback(() => {
    if (session?.user?.id) void fetchProfile(session.user.id);
    else setSessionAttempt((attempt) => attempt + 1);
  }, [fetchProfile, session?.user?.id]);

  const sessionProfile = profile?.id === session?.user?.id ? profile : (profile === null ? null : undefined);
  const resolvedStatus = session && status === "ready" && !sessionProfile ? "loading-profile" : status;
  return { session, profile: sessionProfile, status: resolvedStatus, error, notice, fetchProfile, retry, signOut };
}

export async function withBoundedTimeout(promise, timeoutMs = 8000, message = "انتهت مهلة العملية") {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(message)), timeoutMs); }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

export async function syncMutation({ scope, mutationResult, refetch, refetchTimeoutMs = 8000 }) {
  console.info(`[${scope}] mutationResult`, mutationResult);
  if (mutationResult?.error) {
    console.error(`[${scope}] mutation failed`, mutationResult.error);
    return { mutationResult, refetchResult: null, error: mutationResult.error };
  }

  let refetchResult = null;
  try {
    refetchResult = refetch ? await withBoundedTimeout(Promise.resolve().then(refetch), refetchTimeoutMs, "تم حفظ العملية، لكن انتهت مهلة تحديث الشاشة") : null;
  } catch (error) {
    refetchResult = { data: null, error };
  }
  console.info(`[${scope}] refetchResult`, refetchResult);
  console.info(`[${scope}] currentState`, refetchResult?.data ?? null);
  if (refetchResult?.error) console.error(`[${scope}] refetch failed`, refetchResult.error);
  return { mutationResult, refetchResult, error: null, refreshError: refetchResult?.error || null, mutationSaved: true };
}

export async function runCriticalMutation({ scope, mutate, refetch, verify, mutationTimeoutMs = 12000, refetchTimeoutMs = 8000, verifyTimeoutMs = 8000 }) {
  let mutationResult;
  try {
    mutationResult = await withBoundedTimeout(Promise.resolve().then(mutate), mutationTimeoutMs, "انتهت مهلة إرسال العملية؛ تحقق من حالتها قبل إعادة المحاولة");
  } catch (error) {
    return { mutationResult: null, error, mutationSaved: false, refreshError: null, verificationResult: null };
  }
  if (mutationResult?.error) return { mutationResult, error: mutationResult.error, mutationSaved: false, refreshError: null, verificationResult: null };

  let verificationResult = null;
  if (verify) {
    try {
      verificationResult = await withBoundedTimeout(Promise.resolve().then(() => verify(mutationResult)), verifyTimeoutMs, "تم إرسال العملية، لكن تعذر التحقق من حالتها النهائية");
      if (verificationResult?.error || verificationResult === false) return { mutationResult, verificationResult, error: verificationResult?.error || new Error("تعذر التحقق من الحالة النهائية"), mutationSaved: true, refreshError: null };
    } catch (error) {
      return { mutationResult, verificationResult, error, mutationSaved: true, refreshError: null };
    }
  }
  const settled = await syncMutation({ scope, mutationResult, refetch, refetchTimeoutMs });
  return { ...settled, verificationResult };
}

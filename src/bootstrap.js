export const BOOTSTRAP_TIMEOUT_MS = 12000;

export function withTimeout(promise, timeoutMs = BOOTSTRAP_TIMEOUT_MS, message = "انتهت مهلة الاتصال بالخادم") {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      const error = new Error(message);
      error.code = "NEXTEP_TIMEOUT";
      reject(error);
    }, timeoutMs);
  });

  return Promise.race([Promise.resolve(promise), timeout]).finally(() => clearTimeout(timer));
}

export function bootstrapErrorMessage(error, fallback) {
  if (error?.code === "NEXTEP_TIMEOUT") return error.message;
  return error?.message ? `${fallback}: ${error.message}` : fallback;
}

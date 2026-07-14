export async function syncMutation({ scope, mutationResult, refetch }) {
  console.info(`[${scope}] mutationResult`, mutationResult);
  if (mutationResult?.error) {
    console.error(`[${scope}] mutation failed`, mutationResult.error);
    return { mutationResult, refetchResult: null, error: mutationResult.error };
  }

  let refetchResult = null;
  try {
    refetchResult = refetch ? await refetch() : null;
  } catch (error) {
    refetchResult = { data: null, error };
  }
  console.info(`[${scope}] refetchResult`, refetchResult);
  console.info(`[${scope}] currentState`, refetchResult?.data ?? null);
  if (refetchResult?.error) console.error(`[${scope}] refetch failed`, refetchResult.error);
  return { mutationResult, refetchResult, error: refetchResult?.error || null };
}

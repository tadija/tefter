let csrf = "";

export async function api<T>(
  path: string,
  method = "GET",
  data?: unknown,
): Promise<T> {
  const response = await fetch("/api/v1/" + path, {
    method,
    headers: {
      "Content-Type": "application/json",
      "X-CSRF-Token": csrf,
      "X-Tefter-Login": "1",
    },
    body: data === undefined ? undefined : JSON.stringify(data),
    cache: "no-store",
  });
  if (!response.ok) {
    const detail = await response.json().catch(() => null);
    throw new Error(
      (detail?.error?.message ?? detail?.message ?? "Request failed") +
        " (" +
        response.status +
        ")",
    );
  }
  const value = response.status === 204 ? null : await response.json();
  if (value?.csrf) csrf = value.csrf;
  return value;
}

export async function listing<T>(path: string, key: string): Promise<T[]> {
  let offset: number | undefined = 0;
  const result: T[] = [];
  while (offset !== undefined) {
    const page: { next?: number; [key: string]: unknown } = await api(
      path + "?offset=" + offset,
    );
    result.push(...(page[key] as T[]));
    offset = page.next;
  }
  return result;
}

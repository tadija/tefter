let csrf = ''

export async function api<T>(path: string, method = 'GET', data?: unknown): Promise<T> {
  const response = await fetch('/api/v1/' + path, {
    method,
    headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf, 'X-Tefter-Login': '1' },
    body: data === undefined ? undefined : JSON.stringify(data),
    cache: 'no-store'
  })
  if (!response.ok) throw new Error(`Request failed (${response.status})`)
  const value = response.status === 204 ? null : await response.json()
  if (value?.csrf) csrf = value.csrf
  return value
}

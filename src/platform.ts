// Replace these adapters with Capacitor plugins when adding native shells.
export const storage = {
  get<T>(key: string, fallback: T): T { try { const value = localStorage.getItem('sfn:' + key); return value == null ? fallback : JSON.parse(value); } catch { return fallback; } },
  set(key: string, value: unknown) { try { localStorage.setItem('sfn:' + key, JSON.stringify(value)); } catch { /* Private mode or full storage: keep the in-memory app working. */ } },
};
export const locate = () => new Promise<GeolocationPosition>((resolve, reject) => {
  if (!navigator.geolocation) return reject(new Error('Location is unavailable in this browser. Search for a station instead.'));
  navigator.geolocation.getCurrentPosition(resolve, reject, { enableHighAccuracy: false, timeout: 10000, maximumAge: 60000 });
});
export const base = import.meta.env.BASE_URL;
export async function api<T>(path: string, signal?: AbortSignal): Promise<T> {
  const response = await fetch(base + 'api/v1/' + path, { signal, cache: 'no-cache' });
  if (!response.ok) throw new Error(response.status === 404 ? 'No longer available in the current feed' : 'Could not reach the train feed');
  return response.json();
}

const CACHE = 'sfn-shell-__BUILD_VERSION__';
const scope = new URL(self.registration.scope);
const assets = [/* __PRECACHE__ */];
self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll([scope.pathname, 'icon.svg', 'icon-192.png', 'icon-512.png', 'manifest.webmanifest', ...assets].map(p => new URL(p, scope).pathname))));
});
self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k.startsWith('sfn-shell-') && k !== CACHE).map(k => caches.delete(k)))));
});
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  if (event.request.method !== 'GET' || url.origin !== scope.origin || !url.pathname.startsWith(scope.pathname) || url.pathname.includes('/api/')) return;
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const navigation = event.request.mode === 'navigate';
    const key = navigation ? scope.pathname : event.request;
    if (navigation || url.pathname.includes('/assets/')) {
      const cached = await cache.match(key); if (cached) return cached;
    }
    try {
      const response = await fetch(event.request);
      if (response.ok) await cache.put(key, response.clone());
      return response;
    } catch {
      return await cache.match(key) || new Response('Offline. Open this station once while connected to save its board.', { status: 503, headers: { 'Content-Type': 'text/plain' } });
    }
  })());
});

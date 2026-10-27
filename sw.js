const BASE = new URL('./', self.registration.scope);

self.addEventListener('push', event => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch { data = {}; }
  event.waitUntil(self.registration.showNotification(data.title || 'Santa Padel Club', {
    body: data.body || 'Tenés una novedad en el torneo.',
    tag: data.tag || 'padel-notification',
    data: { url: data.url || BASE.href },
    icon: new URL('icon-192.png', BASE).href,
    badge: new URL('badge-72.png', BASE).href
  }));
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  const target = new URL(event.notification.data?.url || './', BASE).href;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of windows) {
      if (client.url.startsWith(BASE.href) && 'focus' in client) return client.focus();
    }
    return self.clients.openWindow(target);
  })());
});

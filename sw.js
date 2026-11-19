// App shell cache: pages load offline-first for the shell, but always try the network for fresh HTML. API calls are never cached.
const V='dj-v1',SHELL=['./','./index.html','./manifest.webmanifest','./icon-192.png','./icon-512.png'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(V).then(c=>c.addAll(SHELL)));self.skipWaiting()});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==V).map(k=>caches.delete(k)))));self.clients.claim()});
self.addEventListener('fetch',e=>{const u=new URL(e.request.url);if(e.request.method!=='GET'||u.origin!==location.origin)return;
  if(e.request.mode==='navigate'){e.respondWith(fetch(e.request).then(r=>{const c=r.clone();caches.open(V).then(x=>x.put('./index.html',c));return r}).catch(()=>caches.match('./index.html')));return}
  e.respondWith(caches.match(e.request).then(m=>m||fetch(e.request)))});
self.addEventListener('notificationclick',e=>{e.notification.close();const url=e.notification.data?.url||'./';
  e.waitUntil(self.clients.matchAll({type:'window'}).then(cs=>{for(const c of cs){c.navigate(url);return c.focus()}return self.clients.openWindow(url)}))});

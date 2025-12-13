// Version-based cache name - update this when deploying a new version
// IMPORTANT: Change this version number each time you rebuild to force service worker update
const CACHE_VERSION = 'v1';
const CACHE_NAME = 'quiz-pwa-' + CACHE_VERSION;
const urlsToCache = [
  '/',
  '/main.dart.js',
  '/flutter_bootstrap.js',
  '/manifest.json',
  '/icons/Icon-192.png',
  '/icons/Icon-512.png',
  '/favicon.png'
];

// Install event - cache resources and skip waiting to activate immediately
self.addEventListener('install', (event) => {
  console.log('Service Worker installing with cache:', CACHE_NAME);
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => {
        console.log('Opened cache:', CACHE_NAME);
        return cache.addAll(urlsToCache);
      })
      .then(() => {
        // Skip waiting to activate the new service worker immediately
        return self.skipWaiting();
      })
  );
});

// Activate event - clean up old caches and claim clients
self.addEventListener('activate', (event) => {
  console.log('Service Worker activating');
  event.waitUntil(
    caches.keys().then((cacheNames) => {
      return Promise.all(
        cacheNames.map((cacheName) => {
          if (cacheName !== CACHE_NAME) {
            console.log('Deleting old cache:', cacheName);
            return caches.delete(cacheName);
          }
        })
      );
    })
    .then(() => {
      // Claim all clients to ensure the new service worker takes control
      return self.clients.claim();
    })
  );
});

// Fetch event - network first strategy for better update support
self.addEventListener('fetch', (event) => {
  // For main app files, always fetch from network first to get updates
  const url = new URL(event.request.url);
  const isAppFile = url.pathname.includes('.dart.js') || 
                    url.pathname.includes('flutter_bootstrap') ||
                    url.pathname.includes('main.dart.js') ||
                    url.pathname === '/' ||
                    url.pathname.includes('index.html');
  
  if (isAppFile) {
    // For app files, always try network first, never use cache
    event.respondWith(
      fetch(event.request, { cache: 'no-store' })
        .then((response) => {
          return response;
        })
        .catch(() => {
          // Only use cache if network completely fails
          return caches.match(event.request);
        })
    );
  } else {
    // For other files (icons, etc.), use network first but allow cache fallback
    event.respondWith(
      fetch(event.request)
        .then((response) => {
          return response;
        })
        .catch(() => {
          return caches.match(event.request);
        })
    );
  }
});

// Listen for messages from the app
self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
  if (event.data && event.data.type === 'CLEAR_CACHE') {
    caches.keys().then((cacheNames) => {
      return Promise.all(
        cacheNames.map((cacheName) => {
          console.log('Clearing cache:', cacheName);
          return caches.delete(cacheName);
        })
      );
    });
  }
});


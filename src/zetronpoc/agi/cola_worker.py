<!doctype html>
<html lang="en">
  <head>
    <script>
    (function() {
        var buffer = window.__base44_preview_native_failures;
        if (!buffer || buffer.version !== 1 || !Array.isArray(buffer.entries)) {
            buffer = { version: 1, entries: [], listenersInstalled: false };
            window.__base44_preview_native_failures = buffer;
        }
        if (buffer.listenersInstalled) return;
        function value(object, key) {
            return object && typeof object[key] === 'string' ? object[key] : '';
        }
        function append(message) {
            if (!message) return;
            var normalizedMessage = String(message).slice(0, 5000);
            for (var index = buffer.entries.length - 1; index >= 0; index--) {
                var existing = buffer.entries[index];
                if (existing && existing.level === 'error' && existing.message === normalizedMessage) {
                    buffer.entries.splice(index, 1);
                }
            }
            buffer.entries.push({
                level: 'error',
                message: normalizedMessage,
                timestamp: Date.now()
            });
            if (buffer.entries.length > 100) {
                buffer.entries.splice(0, buffer.entries.length - 100);
            }
        }
        buffer.append = append;
        function handleError(event) {
            var target = event && event.target;
            var tagName = value(target, 'tagName').toLowerCase() || 'window';
            var isModule = tagName === 'script' && value(target, 'type').toLowerCase() === 'module';
            var resourceType = isModule ? 'module' : tagName;
            var url = value(target, 'src') || value(target, 'href') || value(event, 'filename');
            var detail = value(event, 'message') || value(event && event.error, 'message');
            var prefix = tagName === 'window' ? 'Native browser error' : 'Failed to load ' + resourceType;
            append(prefix + (url ? ' ' + url : '') + (detail ? ': ' + detail : ''));
        }
        function rejectionReason(reason) {
            if (typeof reason === 'string') return reason;
            var message = value(reason, 'message');
            if (message) return message;
            try { return JSON.stringify(reason) || String(reason); }
            catch (e) { return String(reason); }
        }
        function handleRejection(event) {
            append('Unhandled promise rejection: ' + rejectionReason(event && event.reason));
        }
        function handleCspViolation(event) {
            var blockedUri = value(event, 'blockedURI') || 'resource';
            var directive = value(event, 'violatedDirective');
            append('Content Security Policy blocked ' + blockedUri + (directive ? ' (' + directive + ')' : ''));
        }
        function overlayText(root, selector) {
            var element = root && root.querySelector(selector);
            return value(element, 'textContent').trim();
        }
        function captureViteOverlay(overlay) {
            var root = overlay && overlay.shadowRoot;
            var message = overlayText(root, '.message-body');
            if (!message) return;
            var plugin = overlayText(root, '.plugin');
            var details = ['Vite build error: ' + (plugin ? plugin + ' ' : '') + message];
            var file = overlayText(root, '.file');
            var frame = overlayText(root, '.frame');
            var stack = overlayText(root, '.stack');
            if (file) details.push('File: ' + file);
            if (frame) details.push(frame);
            if (stack) details.push(stack);
            append(details.join(String.fromCharCode(10)));
        }
        function captureViteOverlays(node) {
            if (!node || node.nodeType !== 1) return;
            if (node.matches && node.matches('vite-error-overlay')) captureViteOverlay(node);
            if (!node.querySelectorAll) return;
            var overlays = node.querySelectorAll('vite-error-overlay');
            for (var index = 0; index < overlays.length; index++) captureViteOverlay(overlays[index]);
        }
        window.addEventListener('error', handleError, true);
        window.addEventListener('unhandledrejection', handleRejection);
        window.addEventListener('securitypolicyviolation', handleCspViolation);
        if (typeof MutationObserver !== 'undefined' && document.documentElement) {
            captureViteOverlays(document.documentElement);
            new MutationObserver(function(records) {
                for (var recordIndex = 0; recordIndex < records.length; recordIndex++) {
                    var nodes = records[recordIndex].addedNodes;
                    for (var nodeIndex = 0; nodeIndex < nodes.length; nodeIndex++) {
                        captureViteOverlays(nodes[nodeIndex]);
                    }
                }
            }).observe(document.documentElement, { childList: true, subtree: true });
        }
        buffer.listenersInstalled = true;
    })();
    </script><script defer data-preview-inject="true" data-app-id="6a70b57d18d75346f8ff1fd8" data-preview-type="sandbox" data-rum-app-id="db50c921-10c3-4f12-bccb-950fa174b708" data-rum-client-token="pubfe8a4f2972b412b4556fd67e77f82cb4" data-dd-site="datadoghq.com" src="https://app.base44.com/builder-bridge.js?t=1785774393"></script>
    <script>
    (function() {
        var IGNORE = { SCRIPT: 1, STYLE: 1, LINK: 1, META: 1, NOSCRIPT: 1, TEMPLATE: 1 };
        const fire = () => window.parent.postMessage({ type: 'IFRAME_CONTENT_READY' }, '*');
        function check() {
            var body = document.body;
            if (!body) return false;
            for (var idx = 0; idx < body.children.length; idx++) {
                if (!IGNORE[body.children[idx].tagName]) return true;
            }
            return false;
        }
        function start() {
            if (check()) { fire(); return; }
            var observer = new MutationObserver(function() {
                if (check()) { fire(); observer.disconnect(); }
            });
            observer.observe(document.documentElement, { childList: true, subtree: true });
        }
        if (document.body) { start(); }
        else { document.addEventListener('DOMContentLoaded', start, { once: true }); }
    })();
    </script>
    <script>
    (function() {
        if (window.self === window.top) return;
        var APP_ID = "6a70b57d18d75346f8ff1fd8";
        var PREVIEW_TYPE = "sandbox";
        var on404 = false;
        var booted = false;
        function detect() { return !!document.querySelector('[data-source-location^="PageNotFound:"]'); }
        function payload() { return { app_id: APP_ID, preview_type: PREVIEW_TYPE, url_path: window.location.pathname }; }
        function tick() {
            var now = detect();
            if (now && !on404) {
                on404 = true;
                window.parent.postMessage({ type: 'PREVIEW_PAGE_NOT_FOUND', payload: payload() }, '*');
            } else if (!now && (on404 || !booted)) {
                // On first tick of a fresh document, emit a cleared signal even when
                // not currently on a 404 — the parent may have latched is404=true from
                // a previous document at the same URL (e.g. after an iframe reload).
                on404 = false;
                window.parent.postMessage({ type: 'PREVIEW_PAGE_NOT_FOUND_CLEARED', payload: payload() }, '*');
            }
            booted = true;
        }
        function start() {
            tick();
            new MutationObserver(tick).observe(document.body, { childList: true, subtree: true });
        }
        if (document.body) { start(); }
        else { document.addEventListener('DOMContentLoaded', start, { once: true }); }
    })();
    </script>
    <script>
    (function() {
        if (window.self === window.top) return;
        function fire() { window.parent.postMessage({ type: 'REACT_ROOT_HAS_CHILDREN' }, '*'); }
        function findRoot() {
            return document.getElementById('root')
                || document.getElementById('app')
                || document.querySelector('[data-react-root]');
        }
        // One-shot: wait for DOMContentLoaded (static HTML parsed by then, so the
        // Base44 convention <div id="root"> is either present or not coming),
        // observe the root's childList until the first element child appears,
        // then fire and disconnect. No tree-wide subtree observer.
        function start() {
            var root = findRoot();
            if (!root) return;
            if (root.childElementCount > 0) { fire(); return; }
            var obs = new MutationObserver(function() {
                if (root.childElementCount > 0) { fire(); obs.disconnect(); }
            });
            obs.observe(root, { childList: true });
        }
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', start, { once: true });
        } else { start(); }
    })();
    </script>
    <script>
    (function() {
        if (window.self === window.top) return;
        function postUnsupported(reason) {
            window.parent.postMessage({
                type: 'IFRAME_FIRST_CONTENTFUL_PAINT_UNSUPPORTED',
                payload: { reason: reason, userAgent: navigator.userAgent }
            }, '*');
        }
        if (typeof PerformanceObserver === 'undefined') {
            postUnsupported('no_performance_observer');
            return;
        }
        try {
            var obs = new PerformanceObserver(function(list) {
                var entries = list.getEntries();
                for (var i = 0; i < entries.length; i++) {
                    if (entries[i].name === 'first-contentful-paint') {
                        obs.disconnect();
                        window.parent.postMessage({ type: 'IFRAME_FIRST_CONTENTFUL_PAINT' }, '*');
                        return;
                    }
                }
            });
            obs.observe({ type: 'paint', buffered: true });
        } catch (e) {
            postUnsupported('observe_threw:' + (e && e.name ? e.name : 'Error'));
        }
    })();
    </script>
    <script>
    (function() {
        if (window.self === window.top) return;
        var APP_ID = "6a70b57d18d75346f8ff1fd8";
        var PREVIEW_TYPE = "sandbox";
        var DEPS_PATH = '/node_modules/.vite/deps/';
        var fired = false;
        function isViteDep(url) {
            return typeof url === 'string' && url.indexOf(DEPS_PATH) !== -1;
        }
        function looksFailed(entry) {
            // HTTP failure status (Chrome 109+).
            if (entry.responseStatus && entry.responseStatus >= 400) return true;
            // Aborted / blocked / network-error: request ran, nothing decoded.
            // decodedBodySize === 0 distinguishes from cache hits (Safari has no
            // deliveryType, so we can't rely on it to exclude cached responses).
            return entry.transferSize === 0
                && entry.decodedBodySize === 0
                && entry.duration > 0
                && entry.responseEnd > 0;
        }
        function report(entry) {
            if (fired) return;
            fired = true;
            var nativeBuffer = window.__base44_preview_native_failures;
            if (nativeBuffer && typeof nativeBuffer.append === 'function') {
                nativeBuffer.append('Failed to load module ' + entry.name);
            }
            window.parent.postMessage({
                type: 'SANDBOX_VITE_DEPS_404',
                payload: {
                    app_id: APP_ID,
                    preview_type: PREVIEW_TYPE,
                    url: entry.name,
                    initiator_type: entry.initiatorType,
                    response_status: entry.responseStatus
                }
            }, '*');
        }
        new PerformanceObserver(function(list) {
            var entries = list.getEntries();
            for (var i = 0; i < entries.length; i++) {
                if (isViteDep(entries[i].name) && looksFailed(entries[i])) {
                    report(entries[i]);
                    return;
                }
            }
        }).observe({ type: 'resource', buffered: true });
    })();
    </script>
    <script>
    (function() {
        if (typeof PerformanceObserver === 'undefined') return;
        function modulePath(url) {
            try {
                var path = new URL(url, window.location.href).pathname;
                // The bridge probes this standard SDK path opportunistically;
                // legacy/custom apps are allowed not to provide it.
                if (path === '/src/api/base44Client.js') return '';
                if (path.indexOf('/node_modules/.vite/deps/') !== -1) return '';
                return /[.](?:[cm]?[jt]sx?)$/i.test(path) ? path : '';
            } catch (e) {
                return '';
            }
        }
        new PerformanceObserver(function(list) {
            var entries = list.getEntries();
            for (var index = 0; index < entries.length; index++) {
                var entry = entries[index];
                if (entry.initiatorType !== 'script' || entry.responseStatus !== 404) continue;
                var path = modulePath(entry.name);
                var buffer = window.__base44_preview_native_failures;
                if (path && buffer && typeof buffer.append === 'function') {
                    buffer.append('Module not found: ' + path);
                }
            }
        }).observe({ type: 'resource', buffered: true });
    })();
    </script>
    <script>
    (function() {
        if (window.self === window.top) return;
        if (typeof performance === 'undefined' || typeof performance.getEntriesByType !== 'function') return;
        var DEPS_PATH = '/node_modules/.vite/deps/';
        var QUIESCENCE_MS = 1500;
        var POLL_MS = 500;
        var fired = false;
        var intervalId = setInterval(function() {
            if (fired) return;
            var entries = performance.getEntriesByType('resource');
            var lastDepEnd = 0;
            for (var i = 0; i < entries.length; i++) {
                if (entries[i].name.indexOf(DEPS_PATH) === -1) continue;
                if (entries[i].responseEnd > lastDepEnd) lastDepEnd = entries[i].responseEnd;
            }
            if (lastDepEnd === 0) return;
            if (performance.now() - lastDepEnd >= QUIESCENCE_MS) {
                fired = true;
                clearInterval(intervalId);
                window.parent.postMessage({ type: 'IFRAME_VITE_DEPS_SETTLED' }, '*');
            }
        }, POLL_MS);
    })();
    </script>
        <script type="module">
        try {
            const { base44 } = await import("/src/api/base44Client.js");
            if (base44) {
                Object.defineProperty(window, "base44_sdk", {
                    value: base44,
                    writable: false,
                    configurable: true
                });
            }
        } catch (e) {
            // Some legacy/custom apps may not have the standard client module.
            // Leave window.base44_sdk undefined; PreviewLens can fall back to UI/network checks.
            window.parent.postMessage({ type: "PREVIEW_LENS_SDK_ATTACH_FAILED", error: String(e) }, "*");
        }
        </script>
        <script type="module">
        try {
            const { createHotContext } = await import("/@vite/client");
            const hot = createHotContext("/__builder-bridge-hmr");
            const previewFEVersion = Number(new URLSearchParams(window.location.search).get("previewFE_version")) || 0;
            hot.on("vite:ws:connect", () => window.parent.postMessage({ type: "SANDBOX_WS_CONNECT" }, "*"));
            hot.on("vite:ws:disconnect", () => window.parent.postMessage({ type: "SANDBOX_WS_DISCONNECT" }, "*"));
        
            hot.on("vite:error", (payload) => {
                const err = payload && payload.err && typeof payload.err === "object" ? payload.err : {};
                const message = typeof err.message === "string" ? err.message : "Unknown build error";
                const plugin = typeof err.plugin === "string" ? `[plugin:${err.plugin}] ` : "";
                const details = [`Vite build error: ${plugin}${message}`];
                const loc = err.loc && typeof err.loc === "object" ? err.loc : null;
                let file = loc && typeof loc.file === "string"
                    ? loc.file
                    : (typeof err.id === "string" ? err.id : "");
                if (file) {
                    file = file.split("?")[0];
                    if (loc && Number.isFinite(loc.line) && Number.isFinite(loc.column)) {
                        file += `:${loc.line}:${loc.column}`;
                    }
                    details.push(`File: ${file}`);
                }
                if (typeof err.frame === "string" && err.frame.trim()) details.push(err.frame.trim());
                if (typeof err.stack === "string" && err.stack.trim()) details.push(err.stack.trim());

                const nativeBuffer = window.__base44_preview_native_failures;
                if (!nativeBuffer || typeof nativeBuffer.append !== "function") return;
                nativeBuffer.append(details.join(String.fromCharCode(10)));
            });
    
            // The pending promise holds Vite's pageReload (it awaits listeners) so the parent swaps a fresh iframe; an editor that doesn't announce previewFE_version falls back to today's in-place reload.
            hot.on("vite:beforeFullReload", () => {
                window.parent.postMessage({ type: "sandbox:beforeFullReload" }, "*");
                if (previewFEVersion > 0) return new Promise(() => {});
            });
        } catch (e) {
            window.parent.postMessage({ type: "SANDBOX_WS_ATTACH_FAILED", error: String(e) }, "*");
        }
        </script>
    <script>
    (function() {
        if (window.self === window.top) return;
        var lastUrl = window.location.href;
        function notify() {
            var url = window.location.href;
            if (url === lastUrl) return;
            lastUrl = url;
            window.parent.postMessage({ type: 'APP_CHANGED_URL', url: url }, '*');
        }
        var origPush = history.pushState.bind(history);
        history.pushState = function() { origPush.apply(history, arguments); notify(); };
        var origReplace = history.replaceState.bind(history);
        history.replaceState = function() { origReplace.apply(history, arguments); notify(); };
        window.addEventListener('popstate', notify);
        window.parent.postMessage({ type: 'APP_CHANGED_URL', url: window.location.href }, '*');
    })();
    </script>
    <script type="module">import { injectIntoGlobalHook } from "/@react-refresh";
injectIntoGlobalHook(window);
window.$RefreshReg$ = () => {};
window.$RefreshSig$ = () => (type) => type;</script>

    <script type="module" src="/@vite/client"></script>

    <meta charset="UTF-8" />
    <link rel="icon" type="image/svg+xml" href="https://base44.com/logo_v2.svg" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <link rel="manifest" href="/manifest.json" />
    <title>Base44 APP</title>
      <!-- Tailwind CSS CDN for visual editing -->
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="/node_modules/@base44/vite-plugin/dist/injections/unhandled-errors-handlers.js" type="module"></script>
    <script src="/node_modules/@base44/vite-plugin/dist/injections/sandbox-hmr-notifier.js" type="module"></script>
    <script src="/node_modules/@base44/vite-plugin/dist/injections/navigation-notifier.js" type="module"></script>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx?t=1785774212950"></script>
    <script src="/node_modules/@base44/vite-plugin/dist/injections/sandbox-mount-observer.js" type="module"></script>
    <script type="module">if (window.self !== window.top) {
  const mode = new URLSearchParams(location.search).get("sandbox-bridge");
  const url = mode === "local"
    ? "https://localhost:3201/index.mjs"
    : "/node_modules/@base44/vite-plugin/dist/statics/index.mjs";
  import(url)
    .then(mod => {
      if (typeof mod.setupVisualEditAgent === "function") mod.setupVisualEditAgent();
    })
    .catch(e => console.error("[visual-edit-agent] Failed to load:", e));
}</script>
  </body>
</html>

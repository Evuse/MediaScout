#!/usr/bin/env node
'use strict';

const fs = require('fs');
const http = require('http');
const https = require('https');
const net = require('net');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const args = parseArgs(process.argv.slice(2));
const targetURL = args.url;
const deepScroll = args['deep-scroll'] !== '0';
const includeNetwork = args.network !== '0';
const acceptCookies = args['accept-cookies'] !== '0';
const resultLimit = clampNumber(Number(args.limit || 12), 1, 50);
const headless = args.headless !== '0';
const maxAnalyzeMs = clampNumber(Number(args['max-ms'] || 9000), 3000, 30000);
const isFacebook = isFacebookTarget(targetURL);
const isDribbble = isDribbbleTarget(targetURL);
const facebookTargetVideoId = extractFacebookVideoId(targetURL);

if (!targetURL) {
  fail('URL mancante.');
}

const chromePath = findChrome();
if (!chromePath) {
  fail('Google Chrome, Brave, Chromium o Microsoft Edge non trovati in /Applications.');
}

const logs = [];
const responses = new Map();
const bodyScanTargets = new Map();
const bodyScanPromises = new Set();
const facebookMetaCache = new Map();
let bodyScansCompleted = 0;

main().catch(error => {
  fail(error && (error.stack || error.message) || String(error));
});

async function main() {
  const port = await findFreePort();
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'mediascout-chrome-'));
  logs.push(`Chrome: ${chromePath}`);
  logs.push(`DevTools port: ${port}`);
  logs.push(`Background/headless: ${headless ? 'si' : 'no'}`);
  logs.push(`Risultati max: ${resultLimit}`);
  logs.push(`Budget analisi: ${maxAnalyzeMs}ms`);
  if (isFacebook) logs.push('Facebook mode: cookie consent + chiusura login popup');
  if (isDribbble) logs.push('Dribbble mode: attendo il player video prima dell estrazione.');
  const deadline = Date.now() + maxAnalyzeMs;

  const chromeArgs = [
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${profile}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-networking',
    '--disable-popup-blocking',
    '--window-size=1440,1100',
    'about:blank'
  ];
  if (headless) {
    chromeArgs.splice(chromeArgs.length - 1, 0, '--headless=new', '--hide-scrollbars', '--mute-audio');
  }

  const chrome = spawn(chromePath, chromeArgs, { stdio: ['ignore', 'ignore', 'pipe'] });

  chrome.stderr.on('data', data => {
    const text = String(data).trim();
    if (text && shouldKeepChromeLog(text)) logs.push(`chrome: ${text.slice(0, 240)}`);
  });

  try {
    await waitForChrome(port);
    const target = await createTarget(port);
    const cdp = new CDPClient(target.webSocketDebuggerUrl);
    await cdp.connect();

    cdp.on('Network.responseReceived', params => {
      if (!includeNetwork) return;
      const response = params.response || {};
      const url = response.url || '';
      const headers = lowerHeaders(response.headers || {});
      const contentType = String(headers['content-type'] || response.mimeType || '');
      const size = Number(headers['content-length'] || 0);
      const kind = kindFrom(url, undefined, contentType);
      if (!isAllowedKind(kind)) return;
      addResponse(url, kind, 'chrome network', {
        referer: targetURL,
        contentType,
        size
      });
    });
    cdp.on('Network.responseReceived', params => {
      if (!includeNetwork) return;
      const response = params.response || {};
      const headers = lowerHeaders(response.headers || {});
      const contentType = String(headers['content-type'] || response.mimeType || '');
      if (isTextLikeResponse(params.type, contentType)) {
        bodyScanTargets.set(params.requestId, {
          url: response.url || targetURL,
          contentType
        });
      }
    });
    cdp.on('Network.loadingFinished', params => {
      const target = bodyScanTargets.get(params.requestId);
      if (!target) return;
      bodyScanTargets.delete(params.requestId);
      if (Number(params.encodedDataLength || 0) > 5 * 1024 * 1024) return;
      const promise = cdp.send('Network.getResponseBody', { requestId: params.requestId }, 800)
        .then(result => {
          const body = result && result.body ? String(result.body) : '';
          scanMediaURLsFromText(body, 'response body', target.url);
          bodyScansCompleted++;
        })
        .catch(() => {});
      bodyScanPromises.add(promise);
      promise.finally(() => bodyScanPromises.delete(promise));
    });

    await cdp.send('Network.enable', {}, 2000);
    await cdp.send('Page.enable', {}, 2000);
    await cdp.send('Runtime.enable', {}, 2000);
    await cdp.send('Network.setUserAgentOverride', {
      userAgent: chromeUserAgent()
    }, 2000);

    logs.push(`Navigazione: ${targetURL}`);
    await cdp.send('Page.navigate', { url: targetURL }, 3000).catch(error => {
      logs.push(`Page.navigate non bloccante: ${error.message}`);
    });
    await Promise.race([
      waitForEvent(cdp, 'Page.domContentEventFired', Math.min(1500, timeLeft(deadline))),
      waitForEvent(cdp, 'Page.loadEventFired', Math.min(1500, timeLeft(deadline))),
      sleep(Math.min(1200, timeLeft(deadline)))
    ]).catch(() => {
      logs.push('Primo caricamento timeout: continuo con DOM/network corrente.');
    });
    await sleep(Math.min(200, timeLeft(deadline)));

    if (isFacebook) {
      await handleFacebookInterventions(cdp, deadline);
    } else if (acceptCookies) {
      const consentAction = await tryHandleGenericConsent(cdp);
      logs.push(`Cookie consent: ${consentAction || 'nessun banner evidente'}`);
      if (consentAction) await sleep(Math.min(150, timeLeft(deadline)));
    }

    if (isDribbble) {
      const dribbbleReady = await waitForDribbbleVideo(cdp, deadline);
      logs.push(`Dribbble media: ${dribbbleReady ? 'player video rilevato' : 'nessun player video visibile entro il budget'}`);
      if (dribbbleReady) {
        await sleep(Math.min(180, timeLeft(deadline)));
      }
    }

    if (deepScroll) {
      for (let i = 1; i <= 2 && timeLeft(deadline) > 700; i++) {
        await cdp.send('Runtime.evaluate', {
          expression: `window.scrollTo(0, Math.floor((Math.max(document.body.scrollHeight, document.documentElement.scrollHeight) || 0) * ${i} / 4));`,
          awaitPromise: false
        }, 800).catch(error => logs.push(`scroll ${i}: ${error.message}`));
        await sleep(Math.min(250, timeLeft(deadline)));
      }
    }
    await cdp.send('Page.stopLoading', {}, 500).catch(() => {});
    let domReport = { candidates: [], logs: ['DOM extraction: risultato vuoto'] };
    await waitForBodyScans(deadline);

    if (responses.size >= resultLimit && !isDribbble) {
      domReport = { candidates: [], logs: [`DOM extraction saltata: network ha gia ${responses.size} candidati.`] };
    } else {
      const domResult = await cdp.send('Runtime.evaluate', {
        expression: extractionExpression(includeNetwork),
        returnByValue: true,
        awaitPromise: false
      }, Math.min(isDribbble ? 1800 : 900, timeLeft(deadline))).catch(error => {
        logs.push(`DOM extraction timeout/errore: ${error.message}`);
        return null;
      });

      const raw = domResult && domResult.result && domResult.result.value;
      if (typeof raw === 'string') {
        try {
          domReport = JSON.parse(raw);
        } catch (error) {
          domReport = { candidates: [], logs: [`DOM extraction JSON error: ${error.message}`, raw.slice(0, 500)] };
        }
      }
    }

    const cookieResult = await cdp.send('Network.getAllCookies', {}, Math.min(900, timeLeft(deadline))).catch(() => ({ cookies: [] }));
    const cookies = cookieResult && cookieResult.cookies ? cookieResult.cookies : [];
    const merged = mergeCandidates([...responses.values(), ...(domReport.candidates || [])]);
    const enrichedCount = await enrichSizes(merged, targetURL, cookies, deadline);
    const sorted = sortCandidatesBySize(merged);
    logs.push(...(domReport.logs || []).map(line => `DOM ${line}`));
    logs.push(`Chrome network candidati video/GIF: ${responses.size}`);
    logs.push(`Response body analizzati: ${bodyScansCompleted}`);
    logs.push(`Dimensioni arricchite via HEAD/Range: ${enrichedCount}`);
    logs.push(`Totale candidati unici: ${sorted.length}`);
    logs.push('Ordinamento: peso decrescente');

    await cdp.close().catch(() => {});
    chrome.kill('SIGTERM');
    cleanup(profile);

    process.stdout.write(JSON.stringify({ candidates: sorted.slice(0, resultLimit), logs }));
  } catch (error) {
    chrome.kill('SIGTERM');
    cleanup(profile);
    throw error;
  }
}

function extractionExpression(network) {
  return `
    window.__MEDIA_SCOUT_INCLUDE_NETWORK__ = ${network ? 'true' : 'false'};
    ${extractionScript()}
  `;
}

function extractionScript() {
  return `(function() {
      const logs = [];
      const found = [];
      const seen = new Set();
      const pageURL = (window.location && window.location.href) || '';
      const includeNetwork = window.__MEDIA_SCOUT_INCLUDE_NETWORK__ !== false;
      function section(name, fn) {
        try { const before = found.length; fn(); logs.push(name + ': +' + (found.length - before)); }
        catch (error) { logs.push(name + ' errore: ' + (error && (error.stack || error.message || String(error)))); }
      }
      function absolute(value) {
        if (!value || typeof value !== 'string') return null;
        const trimmed = value.trim();
        if (!trimmed || trimmed.indexOf('data:') === 0 || trimmed.indexOf('blob:') === 0) return null;
        try { return new URL(trimmed, pageURL).href; } catch (e) { return null; }
      }
      function clean(value) {
        if (!value) return null;
        let text = String(value).replace(/\\\\u0026/g, '&').replace(/&amp;/g, '&').replace(/\\\\\\//g, '/');
        try { text = decodeURIComponent(text); } catch (e) {}
        return text;
      }
      function kindFromURL(url, fallback, contentType) {
        const ct = (contentType || '').toLowerCase();
        if (ct.indexOf('gif') >= 0) return 'gif';
        if (ct.indexOf('video') >= 0 || ct.indexOf('mpegurl') >= 0 || ct.indexOf('m3u8') >= 0) return 'video';
        if (ct.indexOf('image') >= 0) return 'image';
        const lowered = (url || '').split('?')[0].toLowerCase();
        if (/\\.gif$/.test(lowered)) return 'gif';
        if (/\\.(mp4|m4v|mov|webm|m3u8|ts)$/.test(lowered)) return 'video';
        if (/\\.(jpg|jpeg|png|webp|avif|heic|tiff|bmp|svg)$/.test(lowered)) return 'image';
        return fallback || 'unknown';
      }
      function isAllowedKind(kind) {
        return kind === 'video' || kind === 'gif';
      }
      function add(rawURL, fallbackType, source, meta) {
        const url = absolute(clean(rawURL));
        if (!url || seen.has(url)) return;
        const kind = kindFromURL(url, fallbackType, meta && meta.contentType);
        if (!isAllowedKind(kind)) return;
        seen.add(url);
        const item = { url, type: kind, source: source || 'pagina', referer: pageURL };
        if (meta && meta.width) item.width = Number(meta.width) || undefined;
        if (meta && meta.height) item.height = Number(meta.height) || undefined;
        if (meta && meta.poster) item.poster = absolute(meta.poster) || undefined;
        if (meta && meta.contentType) item.contentType = String(meta.contentType);
        if (meta && meta.size) item.size = Number(meta.size) || undefined;
        found.push(item);
      }
      function addSrcset(srcset, type, source) {
        if (!srcset) return;
        srcset.split(',').forEach(part => add(part.trim().split(/\\s+/)[0], type, source));
      }
      function addMediaURLsFromText(text, source) {
        if (!text) return;
        const cleaned = clean(text);
        const absolutePattern = /(https?:\\/\\/[^"'<>\\s\\\\]+?\\.(?:mp4|m4v|mov|webm|m3u8|gif)(?:\\?[^"'<>\\s\\\\]*)?)/gi;
        let match;
        while ((match = absolutePattern.exec(cleaned)) !== null) add(match[1], null, source);
        const relativePattern = /((?:\\/(?!\\/)|\\.\\/|\\.\\.\\/)[^"'<>\\s\\\\]+?\\.(?:mp4|m4v|mov|webm|m3u8|gif)(?:\\?[^"'<>\\s\\\\]*)?)/gi;
        while ((match = relativePattern.exec(cleaned)) !== null) {
          const before = cleaned.charAt(match.index - 1);
          if (match[1].charAt(0) === '/' && (before === '/' || before === ':')) continue;
          add(match[1], null, source);
        }
      }
      section('meta', function() {
        document.querySelectorAll('meta[property], meta[name]').forEach(meta => {
          const key = (meta.getAttribute('property') || meta.getAttribute('name') || '').toLowerCase();
          const content = meta.getAttribute('content');
          if (!content) return;
          if (key.indexOf('image') >= 0) add(content, 'image', key);
          if (key.indexOf('video') >= 0 || key.indexOf('player:stream') >= 0) add(content, 'video', key);
        });
      });
      section('video', function() {
        document.querySelectorAll('video').forEach(video => {
          add(video.currentSrc || video.src, 'video', 'video tag', { width: video.videoWidth || video.clientWidth, height: video.videoHeight || video.clientHeight, poster: video.poster });
          video.querySelectorAll('source').forEach(source => add(source.src || source.getAttribute('src'), 'video', 'video source', { width: video.videoWidth || video.clientWidth, height: video.videoHeight || video.clientHeight, poster: video.poster }));
        });
      });
      section('images', function() {
        document.querySelectorAll('img').forEach(img => {
          add(img.currentSrc || img.src || img.getAttribute('src'), 'image', 'img tag', { width: img.naturalWidth || img.clientWidth, height: img.naturalHeight || img.clientHeight });
          addSrcset(img.getAttribute('srcset'), 'image', 'img srcset');
        });
      });
      section('source tags', function() {
        document.querySelectorAll('source').forEach(source => {
          const src = source.src || source.getAttribute('src');
          add(src, kindFromURL(src, 'unknown'), 'source tag');
          addSrcset(source.getAttribute('srcset'), 'image', 'source srcset');
        });
      });
      section('links', function() {
        document.querySelectorAll('a[href]').forEach(anchor => {
          const url = absolute(anchor.getAttribute('href'));
          if (url && kindFromURL(url, null) !== 'unknown') add(url, null, 'link diretto');
        });
      });
      section('attributes', function() {
        document.querySelectorAll('*').forEach(element => {
          Array.from(element.attributes || []).forEach(attribute => addMediaURLsFromText(attribute.value, 'attribute ' + attribute.name));
        });
      });
      section('css background', function() {
        document.querySelectorAll('*').forEach(element => {
          const style = window.getComputedStyle(element);
          const background = style && style.backgroundImage;
          if (!background || background === 'none') return;
          const regex = /url\\((['"]?)(.*?)\\1\\)/g;
          let match;
          while ((match = regex.exec(background)) !== null) add(match[2], 'image', 'css background');
        });
      });
      section('json-ld', function() {
        document.querySelectorAll('script[type="application/ld+json"]').forEach(script => {
          try {
            const json = JSON.parse(script.textContent || '');
            const stack = Array.isArray(json) ? json.slice() : [json];
            let guard = 0;
            while (stack.length && guard < 1000) {
              guard++;
              const node = stack.shift();
              if (!node || typeof node !== 'object') continue;
              ['contentUrl', 'embedUrl', 'thumbnailUrl', 'image', 'url'].forEach(key => {
                const value = node[key];
                if (typeof value === 'string') add(value, null, 'json-ld ' + key);
                if (Array.isArray(value)) value.forEach(v => { if (typeof v === 'string') add(v, null, 'json-ld ' + key); if (v && typeof v === 'object') stack.push(v); });
                if (value && typeof value === 'object') stack.push(value);
              });
              Object.keys(node).forEach(key => { const value = node[key]; if (value && typeof value === 'object') stack.push(value); });
            }
          } catch (error) { logs.push('json-ld parse: ' + String(error.message || error)); }
        });
      });
      section('script text', function() {
        document.querySelectorAll('script').forEach(script => addMediaURLsFromText(script.textContent || '', 'script text'));
      });
      section('html scan', function() {
        const html = document.documentElement ? document.documentElement.outerHTML : '';
        addMediaURLsFromText(html, 'html scan');
      });
      if (includeNetwork) section('network resources', function() {
        performance.getEntriesByType('resource').forEach(entry => { if (kindFromURL(entry.name, null) !== 'unknown') add(entry.name, null, 'network resource'); });
      });
      logs.unshift('Pagina: ' + pageURL);
      logs.push('Totale candidati: ' + found.length);
      return JSON.stringify({ candidates: found.slice(0, ${resultLimit}), logs });
    })()`;
}

class CDPClient {
  constructor(url) {
    this.url = url;
    this.id = 1;
    this.pending = new Map();
    this.listeners = new Map();
  }

  async connect() {
    this.ws = new WebSocket(this.url);
    this.ws.addEventListener('message', event => this.handleMessage(event.data));
    await new Promise((resolve, reject) => {
      this.ws.addEventListener('open', resolve, { once: true });
      this.ws.addEventListener('error', reject, { once: true });
    });
  }

  send(method, params = {}, timeoutMs = 5000) {
    const id = this.id++;
    const payload = JSON.stringify({ id, method, params });
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`CDP timeout: ${method}`));
        }
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.ws.send(payload);
    });
  }

  on(method, callback) {
    if (!this.listeners.has(method)) this.listeners.set(method, []);
    this.listeners.get(method).push(callback);
  }

  handleMessage(raw) {
    const message = JSON.parse(raw);
    if (message.id && this.pending.has(message.id)) {
      const pending = this.pending.get(message.id);
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) pending.reject(new Error(message.error.message || JSON.stringify(message.error)));
      else pending.resolve(message.result);
      return;
    }
    if (message.method && this.listeners.has(message.method)) {
      for (const listener of this.listeners.get(message.method)) listener(message.params || {});
    }
  }

  close() {
    return new Promise(resolve => {
      if (!this.ws || this.ws.readyState >= 2) return resolve();
      this.ws.addEventListener('close', resolve, { once: true });
      this.ws.close();
    });
  }
}

function waitForEvent(cdp, method, timeout) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`Timeout ${method}`)), timeout);
    cdp.on(method, params => {
      clearTimeout(timer);
      resolve(params);
    });
  });
}

async function tryAcceptCookies(cdp) {
  const expression = `(() => {
    const labels = [
      'accept all', 'accept cookies', 'allow all', 'agree', 'i agree', 'ok',
      'accetta tutto', 'accetta tutti', 'accetta', 'acconsento', 'consenti tutto',
      'tout accepter', 'aceptar todo', 'aceptar', 'alle akzeptieren'
    ];
    const nodes = Array.from(document.querySelectorAll('button, [role="button"], input[type="button"], input[type="submit"], a'));
    const visible = element => {
      const rect = element.getBoundingClientRect();
      const style = window.getComputedStyle(element);
      return rect.width > 8 && rect.height > 8 && style.visibility !== 'hidden' && style.display !== 'none' && Number(style.opacity || 1) > 0;
    };
    for (const element of nodes) {
      const text = ((element.innerText || element.value || element.getAttribute('aria-label') || element.textContent || '') + '').trim().toLowerCase();
      if (!text || !visible(element)) continue;
      if (labels.some(label => text === label || text.includes(label))) {
        element.click();
        return text.slice(0, 80);
      }
    }
    return '';
  })()`;

  const result = await cdp.send('Runtime.evaluate', {
    expression,
    returnByValue: true,
    awaitPromise: false
  }, 900).catch(() => null);
  return Boolean(result && result.result && result.result.value);
}

async function tryHandleGenericConsent(cdp) {
  const expression = `(() => {
    const preferred = [
      'accept all', 'accept all cookies', 'allow all', 'allow cookies', 'accept cookies',
      'consenti tutti i cookie', 'accetta tutti i cookie', 'accetta tutto', 'consenti tutto',
      'tout accepter', 'aceptar todo', 'alle akzeptieren'
    ];
    const fallback = [
      'reject all', 'decline all', 'continue without accepting',
      'rifiuta cookie facoltativi', 'rifiuta tutti', 'rifiuta', 'continua senza accettare',
      'tout refuser', 'rechazar todo'
    ];
    const nodes = Array.from(document.querySelectorAll('button, [role="button"], input[type="button"], input[type="submit"], a, div[role="button"]'));
    const visible = element => {
      const rect = element.getBoundingClientRect();
      const style = window.getComputedStyle(element);
      return rect.width > 16 && rect.height > 16 && style.visibility !== 'hidden' && style.display !== 'none' && Number(style.opacity || 1) > 0;
    };
    const tryClick = labels => {
      for (const element of nodes) {
        const text = ((element.innerText || element.value || element.getAttribute('aria-label') || element.textContent || '') + '').trim().toLowerCase();
        if (!text || !visible(element)) continue;
        if (labels.some(label => text === label || text.includes(label))) {
          (element.closest('button, [role="button"], div[role="button"], a') || element).click();
          return text.slice(0, 120);
        }
      }
      return '';
    };
    return tryClick(preferred) || tryClick(fallback) || '';
  })()`;

  const result = await cdp.send('Runtime.evaluate', {
    expression,
    returnByValue: true,
    awaitPromise: false
  }, 900).catch(() => null);
  return result && result.result && result.result.value ? String(result.result.value) : '';
}

async function waitForDribbbleVideo(cdp, deadline) {
  for (let attempt = 0; attempt < 7 && timeLeft(deadline) > 250; attempt++) {
    const result = await cdp.send('Runtime.evaluate', {
      expression: `(() => {
        const video = document.querySelector('video[src], video[currentSrc], .shot-media-container video, .shot-content video');
        if (video) return video.currentSrc || video.src || 'video-tag';
        const playerMeta = document.querySelector('meta[name="twitter:player"][content], meta[property="og:video:url"][content]');
        return playerMeta ? (playerMeta.getAttribute('content') || '') : '';
      })()`,
      returnByValue: true,
      awaitPromise: false
    }, 1000).catch(() => null);

    const value = result && result.result && result.result.value ? String(result.result.value) : '';
    if (value) return true;
    await sleep(Math.min(250, timeLeft(deadline)));
  }
  return false;
}

async function handleFacebookInterventions(cdp, deadline) {
  let cookieAccepted = false;
  let loginClosed = false;

  for (let attempt = 0; attempt < 3 && timeLeft(deadline) > 400; attempt++) {
    if (!cookieAccepted && acceptCookies) {
      cookieAccepted = await clickFacebookCookies(cdp);
      if (cookieAccepted) {
        logs.push(`Facebook cookie: consenso automatico eseguito al tentativo ${attempt + 1}`);
        await sleep(Math.min(220, timeLeft(deadline)));
      }
    }

    loginClosed = await closeFacebookLoginModal(cdp) || loginClosed;
    if (loginClosed) {
      logs.push(`Facebook login popup: chiusura automatica al tentativo ${attempt + 1}`);
      await sleep(Math.min(180, timeLeft(deadline)));
    }

    if (cookieAccepted && loginClosed) break;
    await sleep(Math.min(180, timeLeft(deadline)));
  }

  if (!cookieAccepted) logs.push('Facebook cookie: nessun pulsante "Consenti tutti i cookie" visibile');
  if (!loginClosed) logs.push('Facebook login popup: nessuna finestra di login visibile');
}

async function clickFacebookCookies(cdp) {
  const expression = `(() => {
    const labels = [
      'consenti tutti i cookie',
      'accetta tutti i cookie',
      'allow all cookies',
      'accept all cookies'
    ];
    const nodes = Array.from(document.querySelectorAll('button, [role="button"], div[role="button"], a, span'));
    const visible = element => {
      const rect = element.getBoundingClientRect();
      const style = window.getComputedStyle(element);
      return rect.width > 16 && rect.height > 16 && style.visibility !== 'hidden' && style.display !== 'none' && Number(style.opacity || 1) > 0;
    };
    for (const element of nodes) {
      const text = ((element.innerText || element.textContent || element.getAttribute('aria-label') || '') + '').trim().toLowerCase();
      if (!text || !visible(element)) continue;
      if (labels.some(label => text === label || text.includes(label))) {
        const clickable = element.closest('button, [role="button"], a, div[role="button"]') || element;
        clickable.click();
        return text.slice(0, 120);
      }
    }
    return '';
  })()`;

  const result = await cdp.send('Runtime.evaluate', {
    expression,
    returnByValue: true,
    awaitPromise: false
  }, 900).catch(() => null);
  return Boolean(result && result.result && result.result.value);
}

async function closeFacebookLoginModal(cdp) {
  const expression = `(() => {
    const selectors = [
      '[aria-label="Chiudi"]',
      '[aria-label="Close"]',
      '[aria-label="close"]',
      '[aria-label="chiudi"]',
      'div[role="dialog"] [aria-label="Chiudi"]',
      'div[role="dialog"] [aria-label="Close"]'
    ];
    for (const selector of selectors) {
      const node = document.querySelector(selector);
      if (node) {
        node.click();
        return selector;
      }
    }

    const dialogs = Array.from(document.querySelectorAll('div[role="dialog"]'));
    const visible = element => {
      const rect = element.getBoundingClientRect();
      const style = window.getComputedStyle(element);
      return rect.width > 60 && rect.height > 60 && style.visibility !== 'hidden' && style.display !== 'none' && Number(style.opacity || 1) > 0;
    };
    for (const dialog of dialogs) {
      if (!visible(dialog)) continue;
      const text = (dialog.innerText || '').toLowerCase();
      if (text.indexOf('facebook') >= 0 && (text.indexOf('accedi') >= 0 || text.indexOf('password') >= 0 || text.indexOf('e-mail') >= 0)) {
        const candidates = Array.from(dialog.querySelectorAll('button, [role="button"], div[role="button"], span'));
        for (const node of candidates) {
          const label = ((node.getAttribute('aria-label') || node.innerText || node.textContent || '') + '').trim().toLowerCase();
          if (label === 'chiudi' || label === 'close' || label === 'x' || label === '×') {
            (node.closest('button, [role="button"], div[role="button"]') || node).click();
            return 'dialog-close';
          }
        }
      }
    }
    return '';
  })()`;

  const result = await cdp.send('Runtime.evaluate', {
    expression,
    returnByValue: true,
    awaitPromise: false
  }, 900).catch(() => null);
  if (result && result.result && result.result.value) return true;
  await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', windowsVirtualKeyCode: 27, nativeVirtualKeyCode: 53, key: 'Escape', code: 'Escape' }, 300).catch(() => {});
  await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', windowsVirtualKeyCode: 27, nativeVirtualKeyCode: 53, key: 'Escape', code: 'Escape' }, 300).catch(() => {});
  return false;
}

async function waitForBodyScans(deadline) {
  if (!bodyScanPromises.size) return;
  const timeout = Math.min(550, timeLeft(deadline));
  if (timeout <= 50) return;
  await Promise.race([
    Promise.allSettled(Array.from(bodyScanPromises)),
    sleep(timeout)
  ]);
}

function addResponse(url, type, source, meta) {
  if (!url || /^data:|^blob:/.test(url)) return;
  if (responses.has(url)) return;
  responses.set(url, {
    url,
    type: type || 'unknown',
    source,
    referer: meta.referer,
    contentType: meta.contentType || undefined,
    size: meta.size || undefined
  });
}

function scanMediaURLsFromText(text, source, baseURL) {
  if (!text) return;
  const cleaned = decodeText(String(text));
  const absolutePattern = /(https?:\/\/[^"'<>\s\\]+?\.(?:mp4|m4v|mov|webm|m3u8|gif)(?:\?[^"'<>\s\\]*)?)/gi;
  let match;
  while ((match = absolutePattern.exec(cleaned)) !== null) {
    const url = normalizeURL(match[1], baseURL);
    if (url) addResponse(url, kindFrom(url), source, { referer: targetURL });
  }

  const relativePattern = /((?:\/(?!\/)|\.\/|\.\.\/)[^"'<>\s\\]+?\.(?:mp4|m4v|mov|webm|m3u8|gif)(?:\?[^"'<>\s\\]*)?)/gi;
  while ((match = relativePattern.exec(cleaned)) !== null) {
    const before = cleaned.charAt(match.index - 1);
    if (match[1].charAt(0) === '/' && (before === '/' || before === ':')) continue;
    const url = normalizeURL(match[1], baseURL);
    if (url) addResponse(url, kindFrom(url), source, { referer: targetURL });
  }
}

function decodeText(text) {
  let value = text
    .replace(/\\u0026/g, '&')
    .replace(/&amp;/g, '&')
    .replace(/\\\//g, '/');
  try {
    value = decodeURIComponent(value);
  } catch (_) {}
  return value;
}

function normalizeURL(value, baseURL) {
  try {
    return new URL(value, baseURL || targetURL).href;
  } catch (_) {
    return null;
  }
}

function isTextLikeResponse(resourceType, contentType) {
  const type = String(resourceType || '').toLowerCase();
  const ct = String(contentType || '').toLowerCase();
  if (['document', 'script', 'xhr', 'fetch'].includes(type)) return true;
  return ct.includes('json') || ct.includes('javascript') || ct.includes('html') || ct.includes('text/');
}

function mergeCandidates(items) {
  const bestAudioByFamily = new Map();
  for (const item of items) {
    if (!item || !item.url || !isFacebook) continue;
    const meta = parseFacebookMediaMeta(item.url);
    if (!meta.audioOnly || !meta.familyKey) continue;
    const current = bestAudioByFamily.get(meta.familyKey);
    if (!current || audioCandidateScore(item) > audioCandidateScore(current)) {
      bestAudioByFamily.set(meta.familyKey, {
        url: item.url,
        size: Number(item.size || 0),
        source: item.source || ''
      });
    }
  }

  const seen = new Map();
  let order = 0;
  for (const item of items) {
    if (!item || !item.url) continue;
    if (seen.has(item.url)) {
      const existing = seen.get(item.url);
      if (!existing.poster && item.poster) existing.poster = item.poster;
      if (!existing.width && item.width) existing.width = item.width;
      if (!existing.height && item.height) existing.height = item.height;
      if (!existing.contentType && item.contentType) existing.contentType = item.contentType;
      if (!existing.size && item.size) existing.size = item.size;
      if ((!existing.source || existing.source === 'chrome network') && item.source) existing.source = item.source;
      if (!existing.referer && item.referer) existing.referer = item.referer;
      continue;
    }
    item.type = item.type || kindFrom(item.url, 'unknown', item.contentType);
    if (isFacebook) {
      const meta = parseFacebookMediaMeta(item.url);
      if (meta.familyKey) item.familyKey = meta.familyKey;
      if (!meta.audioOnly && meta.familyKey) {
        const audio = bestAudioByFamily.get(meta.familyKey);
        if (audio && audio.url !== item.url) item.audioURL = audio.url;
      }
    }
    if (!isAllowedKind(item.type)) continue;
    if (isSuppressedCandidate(item)) continue;
    item.order = order++;
    seen.set(item.url, item);
  }
  return [...seen.values()];
}

function audioCandidateScore(candidate) {
  const source = String(candidate.source || '');
  const sourceScore =
    source.includes('chrome network') ? 3000000 :
    source.includes('network resource') ? 2000000 :
    source.includes('response body') ? 1000000 : 0;
  const sizeScore = Number(candidate.size || 0);
  const urlScore = String(candidate.url || '').length;
  return sourceScore + sizeScore + urlScore;
}

async function enrichSizes(candidates, referer, cookies, deadline) {
  let enriched = 0;
  const targets = candidates
    .filter(candidate => !(candidate.size && candidate.size > 0))
    .slice(0, Math.max(resultLimit * 2, 8));

  await Promise.all(targets.map(async candidate => {
    if (timeLeft(deadline) <= 200) return;
    const probe = await probeSize(candidate.url, referer, cookies, deadline).catch(() => null);
    if (!probe) return;
    if (probe.contentType && !candidate.contentType) candidate.contentType = probe.contentType;
    const kind = kindFrom(candidate.url, candidate.type, candidate.contentType);
    if (!isAllowedKind(kind)) return;
    candidate.type = kind;
    if (probe.size && probe.size > 0) {
      candidate.size = probe.size;
      enriched++;
    }
  }));
  return enriched;
}

function sortCandidatesBySize(candidates) {
  return candidates
    .filter(item => item && isAllowedKind(item.type))
    .sort((a, b) => {
      const scoreA = scoreCandidate(a);
      const scoreB = scoreCandidate(b);
      if (scoreA !== scoreB) return scoreB - scoreA;
      return Number(a.order || 0) - Number(b.order || 0);
    })
    .map(item => {
      delete item.order;
      delete item.familyKey;
      return item;
    });
}

function isAllowedKind(kind) {
  return kind === 'video' || kind === 'gif';
}

function scoreCandidate(candidate) {
  const size = Number(candidate.size || 0);
  let score = size;
  if (candidate.type === 'video') score += 1000000;
  if (candidate.type === 'gif') score += 10000;
  if (isFacebook) {
    const meta = parseFacebookMediaMeta(candidate.url);
    if (meta.primary) score += 5000000000;
    if (meta.ad) score -= 3000000000;
    if (meta.uiAsset) score -= 4000000000;
    if (meta.audioOnly) score -= 4500000000;
  }
  return score;
}

function isSuppressedCandidate(candidate) {
  if (!isFacebook) return false;
  const meta = parseFacebookMediaMeta(candidate.url);
  if (meta.uiAsset) return true;
  if (meta.audioOnly) return true;
  if (candidate.type === 'gif' && meta.facebookStatic) return true;
  return false;
}

function kindFrom(url, fallback, contentType) {
  const ct = String(contentType || '').toLowerCase();
  if (ct.includes('gif')) return 'gif';
  if (ct.includes('video') || ct.includes('mpegurl') || ct.includes('m3u8')) return 'video';
  if (ct.includes('image')) return 'image';
  const clean = String(url || '').split('?')[0].toLowerCase();
  if (/\.(gif)$/.test(clean)) return 'gif';
  if (/\.(mp4|m4v|mov|webm|m3u8|ts)$/.test(clean)) return 'video';
  if (/\.(jpg|jpeg|png|webp|avif|heic|tiff|bmp|svg)$/.test(clean)) return 'image';
  return fallback || 'unknown';
}

function lowerHeaders(headers) {
  const out = {};
  for (const key of Object.keys(headers)) out[key.toLowerCase()] = headers[key];
  return out;
}

function parseFacebookMediaMeta(rawURL) {
  if (facebookMetaCache.has(rawURL)) return facebookMetaCache.get(rawURL);
  const meta = {
    facebookStatic: false,
    uiAsset: false,
    ad: false,
    primary: false,
    audioOnly: false,
    familyKey: null
  };
  if (!isFacebook) return meta;
  let parsed;
  try {
    parsed = new URL(rawURL);
  } catch (_) {
    facebookMetaCache.set(rawURL, meta);
    return meta;
  }

  const host = parsed.hostname.toLowerCase();
  const pathName = parsed.pathname || '';
  const efg = parsed.searchParams.get('efg');
  let decodedEfg = '';
  if (efg) decodedEfg = safeDecodeBase64JSON(efg);
  const combined = `${rawURL} ${decodedEfg}`.toLowerCase();

  meta.facebookStatic = host.includes('fbcdn.net') && pathName.includes('/rsrc.php');
  meta.uiAsset = meta.facebookStatic || combined.includes('sprite') || combined.includes('emoji');
  meta.ad = combined.includes('ads_') || combined.includes('"vi_usecase_id":10120') || combined.includes('"video_id":787694470298727') || combined.includes('"video_id":2159161371200990');
  meta.audioOnly = combined.includes('heaac') || combined.includes('audio');
  const familyParts = [];
  const videoId = extractJSONNumber(combined, 'video_id');
  const assetId = extractJSONNumber(combined, 'xpv_asset_id');
  const dashManifestId = extractJSONNumber(combined, 'dash_manifest_video_id');
  if (videoId) familyParts.push(`video:${videoId}`);
  if (assetId) familyParts.push(`asset:${assetId}`);
  if (dashManifestId) familyParts.push(`dash:${dashManifestId}`);
  if (!familyParts.length) {
    const fallbackId = parsed.searchParams.get('id') || parsed.searchParams.get('video_id');
    if (fallbackId) familyParts.push(`query:${fallbackId}`);
  }
  if (familyParts.length) meta.familyKey = familyParts.join('|');
  if (facebookTargetVideoId && combined.includes(`"video_id":${facebookTargetVideoId}`)) {
    meta.primary = true;
  }
  if (!meta.primary && combined.includes('"vi_usecase_id":10122')) {
    meta.primary = true;
  }
  facebookMetaCache.set(rawURL, meta);
  return meta;
}

function extractJSONNumber(text, key) {
  const match = String(text || '').match(new RegExp(`"${key}":(\\d+)`));
  return match ? match[1] : '';
}

async function probeSize(url, referer, cookies, deadline) {
  const timeout = Math.min(500, timeLeft(deadline));
  if (timeout <= 150) return null;
  const head = await httpProbe(url, 'HEAD', referer, cookies, false, timeout).catch(error => ({ error }));
  if (head && !head.error && (head.size || head.contentType)) return head;
  const rangeTimeout = Math.min(550, timeLeft(deadline));
  if (rangeTimeout <= 150) return null;
  const range = await httpProbe(url, 'GET', referer, cookies, true, rangeTimeout).catch(() => null);
  return range;
}

function httpProbe(rawURL, method, referer, cookies, range, timeoutMs) {
  return new Promise((resolve, reject) => {
    let parsed;
    try {
      parsed = new URL(rawURL);
    } catch (error) {
      reject(error);
      return;
    }

    const headers = {
      'User-Agent': chromeUserAgent(),
      'Accept': 'video/*,image/gif,application/vnd.apple.mpegurl,application/x-mpegURL,*/*;q=0.8',
      'Referer': referer || rawURL
    };
    if (range) headers.Range = 'bytes=0-0';
    const cookie = cookieHeaderForURL(parsed, cookies);
    if (cookie) headers.Cookie = cookie;

    const client = parsed.protocol === 'https:' ? https : http;
    const request = client.request(parsed, { method, headers, timeout: timeoutMs }, response => {
      const location = response.headers.location;
      if (location && response.statusCode >= 300 && response.statusCode < 400) {
        response.resume();
        const nextURL = new URL(location, parsed).href;
        httpProbe(nextURL, method, referer, cookies, range).then(resolve, reject);
        return;
      }

      const contentType = String(response.headers['content-type'] || '');
      const size = parseContentSize(response.headers);
      response.resume();
      resolve({ size, contentType });
    });

    request.on('timeout', () => request.destroy(new Error('probe timeout')));
    request.on('error', reject);
    request.end();
  });
}

function parseContentSize(headers) {
  const range = String(headers['content-range'] || '');
  const match = range.match(/\/(\d+)$/);
  if (match) return Number(match[1]);
  const length = Number(headers['content-length'] || 0);
  return Number.isFinite(length) ? length : 0;
}

function cookieHeaderForURL(parsedURL, cookies) {
  const host = parsedURL.hostname;
  const pathName = parsedURL.pathname || '/';
  const secure = parsedURL.protocol === 'https:';
  return cookies
    .filter(cookie => {
      if (cookie.secure && !secure) return false;
      const domain = String(cookie.domain || '').replace(/^\./, '');
      const domainMatch = host === domain || host.endsWith('.' + domain);
      const pathMatch = pathName.startsWith(cookie.path || '/');
      return domainMatch && pathMatch;
    })
    .map(cookie => `${cookie.name}=${cookie.value}`)
    .join('; ');
}

function chromeUserAgent() {
  return 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';
}

async function waitForChrome(port) {
  for (let i = 0; i < 80; i++) {
    try {
      await httpJSON(`http://127.0.0.1:${port}/json/version`);
      return;
    } catch (_) {
      await sleep(250);
    }
  }
  throw new Error('Chrome DevTools non si e avviato in tempo.');
}

async function createTarget(port) {
  try {
    return await httpJSON(`http://127.0.0.1:${port}/json/new?about:blank`, 'PUT');
  } catch (_) {
    const list = await httpJSON(`http://127.0.0.1:${port}/json/list`);
    const page = list.find(item => item.type === 'page' && item.webSocketDebuggerUrl);
    if (!page) throw new Error('Nessun target Chrome disponibile.');
    return page;
  }
}

function httpJSON(url, method = 'GET') {
  return new Promise((resolve, reject) => {
    const request = http.request(url, { method }, response => {
      let data = '';
      response.setEncoding('utf8');
      response.on('data', chunk => { data += chunk; });
      response.on('end', () => {
        if (response.statusCode < 200 || response.statusCode >= 300) {
          reject(new Error(`HTTP ${response.statusCode}: ${data}`));
          return;
        }
        try { resolve(JSON.parse(data)); } catch (error) { reject(error); }
      });
    });
    request.on('error', reject);
    request.end();
  });
}

function findFreePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      server.close(() => resolve(port));
    });
    server.on('error', reject);
  });
}

function findChrome() {
  const candidates = [
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
    '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge'
  ];
  return candidates.find(file => fs.existsSync(file));
}

function clampNumber(value, min, max) {
  if (!Number.isFinite(value)) return min;
  return Math.max(min, Math.min(max, Math.floor(value)));
}

function cleanup(folder) {
  try {
    fs.rmSync(folder, { recursive: true, force: true });
  } catch (_) {}
}

function shouldKeepChromeLog(text) {
  const ignored = [
    'CVDisplayLinkCreateWithCGDisplay failed',
    'Trying to load the allocator multiple times'
  ];
  return !ignored.some(fragment => text.includes(fragment));
}

function isFacebookTarget(url) {
  try {
    const host = new URL(url).hostname.toLowerCase();
    return host === 'facebook.com' || host.endsWith('.facebook.com') || host === 'm.facebook.com' || host === 'mbasic.facebook.com';
  } catch (_) {
    return false;
  }
}

function isDribbbleTarget(url) {
  try {
    const host = new URL(url).hostname.toLowerCase();
    return host === 'dribbble.com' || host.endsWith('.dribbble.com');
  } catch (_) {
    return false;
  }
}

function extractFacebookVideoId(url) {
  try {
    const parsed = new URL(url);
    const reelMatch = parsed.pathname.match(/\/reel\/(\d+)/);
    if (reelMatch) return reelMatch[1];
  } catch (_) {}
  return '';
}

function safeDecodeBase64JSON(value) {
  try {
    let normalized = value.replace(/-/g, '+').replace(/_/g, '/');
    while (normalized.length % 4 !== 0) normalized += '=';
    return Buffer.from(normalized, 'base64').toString('utf8');
  } catch (_) {
    return '';
  }
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function timeLeft(deadline) {
  return Math.max(50, deadline - Date.now());
}

function parseArgs(values) {
  const out = {};
  for (let i = 0; i < values.length; i++) {
    const value = values[i];
    if (value.startsWith('--')) {
      out[value.slice(2)] = values[i + 1];
      i++;
    }
  }
  return out;
}

function fail(message) {
  process.stderr.write(String(message) + '\n');
  process.exit(1);
}

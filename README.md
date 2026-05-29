# MediaScout

MediaScout e una app macOS nativa per analizzare una URL, individuare video e GIF presenti nella pagina e scaricarli.

## Cosa fa ora

- Usa Chrome/Chromium locale in background tramite Chrome DevTools Protocol, con profilo separato rispetto al browser dell'utente.
- Cerca solo video e GIF in meta tag, tag `img`, `video`, `source`, JSON-LD, link diretti, HTML renderizzato e risorse di rete.
- Prova ad accettare banner cookie comuni prima dell'estrazione.
- Mostra i primi risultati utili, anteprime quando disponibili, log tecnici e consente di scaricare nella cartella `Downloads`.
- Include il menu Modifica macOS, quindi `Cmd+C`, `Cmd+V`, `Cmd+X` e `Cmd+A` funzionano nei campi di testo.

## Avvio

```bash
swift run MediaScout
```

Con i soli Command Line Tools Apple, se `swift run` fallisce per la mancanza di `xctest`, usa lo script incluso:

```bash
chmod +x scripts/build-app.sh
scripts/build-app.sh
open dist/MediaScout.app
```

## Limiti della prima versione

Alcuni siti proteggono i file con autenticazione, token temporanei, DRM, CORS, contenuti `blob:` o regole anti-scraping. Questa versione individua molte sorgenti pubbliche e renderizzate, e in modalita Chrome/Chromium vede anche le richieste di rete del browser locale headless, ma non aggira DRM, paywall, login non autorizzati o restrizioni del sito.

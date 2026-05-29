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

## Workflow Git consigliato

Questo repository GitHub e la fonte di verita del progetto:

- repo: `git@github.com:Evuse/MediaScout.git`
- `main`: stato stabile e sincronizzato
- `develop`: ramo di lavoro continuo
- `feature/...`: modifiche isolate quando vuoi lavorare in modo piu ordinato

Routine consigliata su qualsiasi macchina:

```bash
git checkout develop
git pull
```

Quando chiudi una modifica:

```bash
git add .
git commit -m "Messaggio chiaro"
git push
```

Se vuoi fare una modifica isolata:

```bash
git checkout develop
git pull
git checkout -b feature/nome-modifica
```

Poi, quando la modifica e pronta:

```bash
git checkout develop
git merge feature/nome-modifica
git push
```

## Note pratiche

- Non committare `dist/`, `DerivedData/`, `.build/` o zip temporanei.
- Se lavori con un'altra AI, falle usare sempre una copia clonata da GitHub e chiudere il lavoro con `commit` + `push`.
- Prima di lavorare da una macchina diversa, fai sempre `git pull`.

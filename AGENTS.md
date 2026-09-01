# Working in this repo

Sessions is an Electron app with no bundler and no build step: `src/main.js` (main
process), `src/preload.js` (IPC bridge), `src/renderer/` (plain DOM, no framework),
`src/indexers/` (one parser per tool), `src/live.js` (which sessions a running CLI owns).

## After each change

Run all three, in order, every time:

```bash
npm run install-app
git add -A && git commit -m "<what the change does>"
git push origin main
```

`npm run install-app` packages the app and replaces the copy in `/Applications`, so
the running app picks the change up. A change that is not installed is not testable.

## Commit messages

One line, present tense, naming the behavior a user sees — "Show the name you gave a
session with /rename", not "Add customTitle handling". No body unless the change needs
one.

## Branches

Work on `main` unless asked otherwise. A new branch is named `mz-<topic>`.

## Changing an indexer

`src/indexers/index.js` caches each parsed transcript by `version:mtimeMs:size`. If a
change alters what a parser returns for a file that has not changed on disk, bump the
version prefix or the old values survive the reinstall.

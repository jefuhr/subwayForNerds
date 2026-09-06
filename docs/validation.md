# Validation — September 6, 2026

## Completed

- Production TypeScript/Vite build passes.
- 17 data/API regression tests pass, including all nine recorded protobuf feeds,
  present/absent extension fields, stable identity, track mismatches, stale and
  failed feeds, station-complex separation, Brighton/Lex local–express inference,
  compatible static patterns, direct-train ranking and conditional HTTP requests.
- 12 Playwright checks pass across desktop Chromium and mobile Chromium: board
  rendering, keyboard dismissal, search, favorites, restoration, route/direction
  filters, ten themes, train/station panels, denied geolocation and offline PWA
  recovery. No horizontal overflow at 1440px or 390px in the captured views.
- Live requests successfully decoded all eight subway/SIR feed groups and subway
  alerts. The catalog contains 445 complexes / 496 constituent stations. A live
  Union Square station-context response returned nine entrances, seven equipment
  records and two outage records; these counts are a snapshot, not current advice.
- Regular and supplemented GTFS downloads and worker-thread parsing succeeded.
  All adjacent stop pairs in the three curated corridors were verified against
  the downloaded GTFS stop sequences, including Brighton's curved southern end.
- `npm audit` reports zero vulnerabilities.

## Performance

Measured against the local production server with live polling active. The API
test sends 500 requests with 50 concurrent clients. Browser measurements use a
390×844 viewport, 70ms emulated network latency, 10Mbps download, 4Mbps upload,
and 4× CPU throttling. The mark records the first React layout commit containing
train rows; it is not an on-device paint measurement. Each cold run uses a fresh
browser context. Repeat runs use the installed, versioned service-worker shell.

| Measurement | Result | Target |
| --- | --- | --- |
| Station API p50 | 34ms | — |
| Station API p95 | 75ms | <100ms |
| Cold usable board, five runs | 546–581ms | <1500ms |
| Cached repeat board, five runs | 148–175ms | <200ms |

These measurements came from the September 6 05:52 UTC benchmark. They describe
this machine/profile, not a guarantee of network speed or MTA source freshness.
`scripts/benchmark.mjs` reproduces the checks and records `artifacts/performance.json`.

## Environment limitations

The host is Arch Linux with no Docker daemon or Compose plugin. Docker/Compose configuration is
provided but the image has not been built or run here. The non-container production
server was exercised directly.

Chromium required isolated runtime libraries and fonts under
`/tmp/subway-browser-libs.R6e8QX`; no system packages were installed. The tests ran
with that directory's `usr/lib` in `LD_LIBRARY_PATH` and its `fonts.conf` in
`FONTCONFIG_FILE`. These are local environment accommodations, not app dependencies.

WebKit downloaded successfully, but the Ubuntu fallback binary needs additional
GTK/GStreamer/ICU/codec libraries absent on this unsupported host. iOS Safari and
physical home-screen behavior have not been verified. On a supported machine:

```sh
npx playwright install --with-deps chromium webkit
RUN_WEBKIT=1 npm run test:browser
```

The initial local verification did not modify the live site, DNS, or reverse proxy.

## Production deployment preparation

The existing juliet.nyc host uses Node 22 and a dedicated systemd service at
`/opt/subways-for-nerds`; its nginx prefix already matches this build. The runtime
lockfile matches the installed dependencies. The initial deployed revision serves
the API but has no built frontend.

For the host's 2GB RAM budget, schedule archives are now parsed sequentially and
CSV input is chunked into 64KiB blocks. A live refresh of both archives completed
in 9.9 seconds at 377MB process peak RSS in the isolated local worker check,
producing 257 regular and 258 supplemented patterns.

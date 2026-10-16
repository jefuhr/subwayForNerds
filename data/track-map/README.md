# NYC track topology: local source annotation

This is a **partial** reusable node/edge/platform graph, aligned to the main map in vanshnookenraggen's NYC Track Map v2.6.8. It is not a replacement schematic and is not a complete passenger-track network. `coverage.json` provides the current counts, per-route coverage and missing station anchors. `nyc-2.6.8-v1.json` implements the coordinator's unchanged `TrackMapTopology` contract.

## Source and distribution

Source: https://www.vanshnookenraggen.com/_index/docs/NYC_full_trackmap.pdf

- Author: vanshnookenraggen.
- Version: 2.6.8; one page, 7,344 × 11,540.6 PDF points, rotation 0.
- Source size: 1,320,628 bytes.
- SHA-256: `b28f75397b2e7b6ba0b67db6ea2181800baa0254a48261252f3d55c4f2b17c71`.
- Coordinates use a **top-left** origin. Extraction applies PDF graphics-state transforms, then converts the native bottom-left origin.
- Local development and analysis only. Written consent is required before distributing the source artwork. The PDF and rendered evidence remain in ignored `artifacts/track-map/`; no permission to distribute the traced artwork is asserted by this dataset.

## Evidence and method

`annotations.json` contains explicitly selected PDF painted-path IDs, original vector commands and manually reviewed rail chains. A negative ID reverses the source path. Multi-moveto paths require an explicit `{pathId, subpath, reverse}` reference; shared paint IDs do not imply connected subpaths. Path IDs are tied to this exact PDF hash and native scanner traversal; they are not stable across map versions. Native extraction finds 14,288 painted paths, 2,316 selectable label lines, 47,195 cubic-curve operators and 21,181 line operators. There are no Form XObjects in this source. The extractor rejects unsupported Form XObjects and nonzero page rotation instead of silently dropping geometry.

The builder adaptively flattens cubic Beziers at a default 0.05-point control-hull error bound; selected chains use a finer 0.005-point bound. Only explicitly annotated adjacent source paths can join. Most seams are limited to 0.03 points; a reviewed Canarsie seam permits 0.22 and Broadway-Seventh Avenue permits 0.11. The seam endpoint is collapsed, introducing at most the recorded seam displacement; this is a numerical source rounding tolerance, not evidence of a new switch. `provenance.json` records each measured maximum seam, station-to-rail projection and explicit junction projection. Explicitly reviewed overlaps may clip an existing path at another source endpoint, including Atlantic Avenue and the local branch south of Broadway-Lafayette. No line is extended across a gap.

Station anchors are averages of selected source platform centers: arc-length midpoints for stroked markers and area centroids for filled platform outlines. Label matching and approximate geographic projections were used only to find review candidates. Their candidate coordinates never become output geometry. The candidate review JSON files record accepted/rejected candidates; manual corrections are recorded separately when needed. Station IDs are the catalog complex IDs, while `partId` retains the platform-group/catalog row ID.

Track crosswalks combine physical source-rail annotation with frozen public MTA feed observations decoded by the existing `server/decode.ts`. `track-code-evidence.json` includes actual and scheduled track strings, feed timestamps and payload hashes. These observations are a dated sample, not proof of all permitted operating moves. `provenance.json` distinguishes a direct observation at the exact stop/code from an observed code carried along the same explicitly annotated continuous rail. The feed does not supply physical PDF coordinates and the source artwork has no printed MTA track codes. A direct-feed witness therefore proves the observed stop/code, while the physical rail association remains a separately reviewed annotation. `physical-code-reviews.json` records primary physical-code references where available, including the NYCT 23 Street Eighth Avenue station plan; historical references are corroborated with current geometry and observations. Track codes are case-sensitive strings. A route letter is never substituted for a physical track code.

## Connectivity and limitations

The graph currently anchors all 475 subway station parts. It maps 932 of 950 catalog-derived directional stop IDs through 1,052 platform crosswalks; 18 directional IDs remain unresolved. The separate observed-code audit maps 1,034 of 1,146 captured stop/track-code pairs, with 112 unresolved. `coverage.json` records every observed pair's status and reason, as well as per-route coverage and missing direction IDs. A station-direction count is not a count of every physical track.

Accepted rail chains cover the L; Brighton Atlantic/7 Avenue and Prospect Park–Sheepshead fragments; Astoria Ditmars–39 Avenue; Crosstown Court Square–Fulton; Flushing local/center and terminal fragments; both active 42 Street Shuttle rails; the Franklin shuttle; Pelham and Dyre outer branches; West End Fort Hamilton–Bay 50; Broadway local 242 Street–South Ferry; Broadway express/Lenox 148 Street–Chambers; White Plains Road 241 Street–149 Street; Jerome Woodlawn–138 Street; Nostrand President–Flatbush; Clark/Eastern Parkway/New Lots; Liberty plus both Rockaway branches; Lexington local/express fragments and the Lower Manhattan–Brooklyn express through rails; Queens Boulevard local/express fragments with Archer and Hillside branches; Eighth Avenue/CPW local and express fragments; Concourse outer rails; Sixth Avenue local/express fragments and lower local rails to York Street; Fulton local/express rails; Fourth Avenue/Bay Ridge; Sea Beach fragments; Second Avenue and 63 Street fragments; Culver locals; Brighton extensions to Ocean Parkway/W 8 Street; and reviewed Nassau/Broadway/Myrtle south physical rails. These names do not imply all platforms, operating moves or intervening trunk connections are available.

Explicit shared nodes comprise reviewed Lenox/White Plains merges, Liberty/Hammels branches Rogers local/express-to-Nostrand branches and Hoyt/Fulton branches, separately annotated by direction. The source artwork's grade-separated crossings remain disconnected. Aqueduct Racetrack has only a northbound platform: the catalog-derived `H01S` denominator entry remains unresolved. Feed stop `H19`/track `F6` lacks a corresponding catalog row and is not invented. `unresolved-geometry.json` separately records measured painted-vector gaps: these prevent traversal even when stations on both sides have crosswalks. The Utica–Sutter northbound rail, Chambers–Clark transitions, Lexington Grand Central/Union Square and Queens Elmhurst/36 Street/53 Street transitions are examples.

Sixth Avenue's physical code assignments are anchored by the NYCT 34/42 Street signal plan and ESD Herald Square platform plan, then independently traced in this PDF and corroborated with frozen stop/code witnesses. West 4 Street includes short, disconnected source fragments. Their boundary nodes terminate at the original painted endpoints and each belongs to exactly one chain; they do not create switches or bridge gaps. The Atlantic/7 Avenue Brighton rails also remain disconnected from the Prospect Park fragments where the source paint has gaps.

Parallel rails remain separate except at individually reviewed same-rail branch nodes. Crossing coordinates never create graph connections. Each node belongs to a specific annotated rail; this keeps crossings and stacked levels separate even when their coordinates overlap. Bidirectional edges are explicit for reversible center/shuttle tracks. Express rails pass local-only stations without gaining platform crosswalks. For example, an observed `M` value at a local-only Flushing stop does not authorize adding a center-track platform.

Crossovers, terminal turnbacks and yard tracks are not certified. Many center tracks and trunk corridors remain unannotated. The Rockaway shuttle branch rails are represented, but its Broad Channel terminal reversal and F6 crosswalk remain unresolved. A mapped stop means at least one crosswalk exists, not that every track/code at that stop is supported. Consumers must constrain traversal using adjacent live stops and actual/scheduled track codes and return unresolved when the selected rail, direction or path is missing. Do not connect disconnected components by proximity or draw a straight-line shortcut.

All 475 subway catalog station parts, including the three shuttles, participate in the coverage denominator. SIR is excluded by route membership, not an `S` prefix, which would incorrectly exclude Franklin shuttle stops. PATH and regional railways are not part of the graph. Only main-map station geometry is accepted; inset diagrams are not alternative train locations.

## Reproduction and validation

Run from the repository root on macOS with the existing lockfile's TypeScript tools available. No new PDF parsing package is required. Swift uses the system PDFKit/CoreGraphics frameworks.

```sh
mkdir -p artifacts/track-map
curl --fail --location --max-time 60 'https://www.vanshnookenraggen.com/_index/docs/NYC_full_trackmap.pdf' --output artifacts/track-map/NYC_full_trackmap.pdf
shasum -a 256 artifacts/track-map/NYC_full_trackmap.pdf
swift scripts/track-map/extract.swift extract artifacts/track-map/NYC_full_trackmap.pdf artifacts/track-map/extracted.json
node_modules/.bin/tsx scripts/track-map/verify-source.ts artifacts/track-map/extracted.json
node_modules/.bin/tsx scripts/track-map/build.ts artifacts/track-map/NYC_full_trackmap.pdf
node_modules/.bin/tsx --test test/track-map-topology.test.ts
```

The source verification compares every selected source path to a fresh native extraction, including curve control points and graphics styles. The builder checks source identity, unique IDs, bounds, finite coordinates, endpoint continuity, zero-length edges, orphan nodes, valid platform references and coverage consistency. Focused graph tests check directed full-L journeys, independent parallel rails, grade crossings, Brighton/Broadway express versus local behavior, bidirectional shuttle/center tracks, and the Franklin-versus-SIR coverage boundary. Synthetic geometry occurs only in tests.

The optional feed capture script makes one bounded, read-only request per requested feed; snapshots are not needed for deterministic rebuilds because the reviewed summary is checked in. Re-capture is a new dated evidence sample, not a requirement to silently change annotations.

```sh
node_modules/.bin/tsx scripts/track-map/capture-tracks.ts gtfs gtfs-ace gtfs-bdfm gtfs-g gtfs-jz gtfs-l gtfs-nqrw
node_modules/.bin/tsx scripts/track-map/summarize-tracks.ts
```

Representative local alignment renders use magenta graph edges and cyan station anchors over the source PDF:

```sh
swift scripts/track-map/extract.swift render artifacts/track-map/NYC_full_trackmap.pdf artifacts/track-map/broadway-overlay.png 1300 5000 600 1100 1.4 data/track-map/nyc-2.6.8-v1.json
swift scripts/track-map/extract.swift render artifacts/track-map/NYC_full_trackmap.pdf artifacts/track-map/brighton-overlay.png 2050 8400 650 2450 0.7 data/track-map/nyc-2.6.8-v1.json
```

`review-atlas.swift` creates local contact sheets from candidate anchors, and `review-paths.swift` labels source paths in a selected crop. These are inspection aids, not automatic topology classifiers. A passing graph validator cannot establish that a platform has been semantically identified correctly; native PDF visual review remains necessary. No native application, device, simulator or end-to-end train animation was exercised by this topology work.

`chain.platformDirections` optionally lists exact feed-direction suffix aliases for an explicit catalog part. Each additional direction requires a direct exact stop/code witness. The chain's original direction retains its already reviewed direct or continuous-rail evidence. Aliases share one physical node; `chain.direction` continues to determine edge orientation, so aliasing does not create reverse traversal or duplicate geometry.

`fragments/jamaica-myrtle.json` preserves the independent 35-part physical review and its 70 nominal direction records. Only its explicitly promoted `chains` and `junctions` are copied into canonical annotations; all other physical switches remain inventory, not operating authorization. Its resolved and unresolved stop/code pairs are separate. The Essex physical witness is first-hand ERA reporting of historical contract engineering layouts, not an authenticated NYCT original; current asymmetric platforms, exact source continuity and frozen codes corroborate the bounded promotions.

The native `review-rails.swift` inspection tool labels width-one painted source rails in a requested main-map crop. It is an annotation aid only; labels and proximity do not accept junctions. New accepted coverage includes Inwood/CPW express fragments, Concourse outer rails with a documented Bedford operating discontinuity, Culver locals through Bergen Street, the Franklin shuttle single-track/terminal branches, and Broadway local fragments. Historical primary NYCT Concourse figures establish physical west C1/east C2; center C34/C6 labels are not automatically equated to current feed CM.

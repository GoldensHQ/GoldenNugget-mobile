# Desktop synchronization — 2026-11-24 (desktop `main`)

Reference: fresh clone of `GoldensHQ/GoldenNugget`, branch `main`, first at
`78d5590` (the 9.7.9 release line) and then re-fetched to `413ee44` (9.7.10),
fetched with the GitHub CLI into `/tmp/opencode/GoldenNugget-main` with its
`awesomeui` and `i18n` submodules. The adjacent `~/GoldenNugget` checkout on
`10.0` (`e005a74`) was also consulted for context, but only `main` behavior was
ported. No Desktop source was modified.

Baseline: desktop tag `9.7.7` (`7f45368`), the reference for the previous mobile
sync. The intervening functional commits are `0d8af73` (empty-plist ScreenTime
fix and repository-pointer updates), `0f64d7b` (HotLoad `Path` fix), `018e171`
(community catalog Pages URL) and the 9.7.8/9.7.9 version bumps. Translation and
Qt-resource refreshes are desktop-only and were not ported.

## Second pass — desktop `main` `413ee44`

The re-fetch added two functional commits after `78d5590`:

- `f136460` — write-only `.gnmpreset` compatibility export. Desktop emits one
  plain-YAML document with a shared `HEADER`, a complete v3-style YAML block and
  a complete legacy v2 JSON block; local storage and imports stay v2.
- `413ee44` — `GNUGGET_VERSION` writer stamp on every settings write and the
  9.7.10 version bump.

Only that main-line subset was ported. The broader preset-v3 reader/writer on
desktop's `10.0` branch was deliberately left out.

- `Nugget/Core/MergedPresetExport.swift` reproduces the document shape with
  Foundation only (no YAML dependency). JSON scalar syntax is valid YAML flow
  syntax, so both blocks stay complete and the v2 block remains parseable by an
  older build. Full and partial exports both feed it through
  `GoldenNuggetPresets.exportData(for:include:)`.
- `PresetManagerView`'s Export and Partial Export actions now choose between
  Merged (recommended, the suggested extension), JSON, and Portable
  `.gnpreset`. The file importer and community import path still accept only
  JSON/`.gnpreset`; merged files are write-only.
- `Nugget/Core/SettingsVersionStamp.swift` maps desktop's single
  `Settings.setValue` hook to mobile's many `UserDefaults` writers. A launch-time
  `didChangeNotification` observer stamps the current short version after a real
  preference write; reads never create the key, and the stamp's own write does
  not recurse.
- Version metadata advanced to `9.7.10` / build `12`: `CFBundleShortVersionString`,
  `CFBundleVersion`, `MARKETING_VERSION`, and `CURRENT_PROJECT_VERSION`.
- The offline desktop-sync harness gained merged-document, write-only-import,
  and writer-stamp checks. The standalone renderer was also exercised outside
  the app to confirm both literal blocks parse.

## Generated sources

All six generators already match this reference; no generated file needed a
rewrite:

- `TweakCatalog.swift` + 10 `TweakCatalog+RegistryN.swift` chunks — 369 tweaks.
- `TweakCatalogDaemons.swift` — 53 groups.
- `PosterBoardResources.swift`, `PosterBoardTemplates.swift`,
  `SkipSetupCatalog.swift`, `PosterKitOptions.swift` — unchanged.

The 10.0-branch generated output from earlier in this session was discarded with
the requested reset before this sync.

## Manual port

- Repository pointers moved from `GoldenNugget-Team` to `GoldensHQ` in
  `AppRelease.swift`, `HotLoadService.rulesURL`, `CommunityCatalog.indexURL`
  (`https://goldenshq.github.io/GoldenNugget-Presets/index.json`),
  `CommunityCatalog.repositoryURL`, the TemplateBuilder link in
  `TemplatesView.swift`, the HotLoad check fixture, `docs/hotload-and-updates.md`
  and the live README links. Historical changelog/sync references and the
  CoreUi-car credit were left intact.
- Desktop's HotLoad `Path(_rules_path())` fix needs no mobile change: the port
  already writes cached rules with `Data.write(..., options: .atomic)`.
- Desktop's extra `_is_clear_file_payload` baseline guard is specific to the
  Python merge path. The mobile compiler already routes
  `ClearScreenTimeAgentPlist` through its `nullified` list and writes a valid
  empty plist rather than zero bytes, so no mobile change was needed.
- Mobile version metadata now matches the 9.7.9 line: `CFBundleShortVersionString`
  `9.7.9`, `CFBundleVersion` `11`, `MARKETING_VERSION` `9.7.9`,
  `CURRENT_PROJECT_VERSION` `11`.

## Validation

- All six `gen-*-from-goldennugget.py --check` gates pass against both
  `78d5590` and `413ee44`; those commits changed no generated catalog source.
- `check-protective-filters.py`: 31 passed, 0 failed.
- `scripts/compile-localizations.py --check` and `git diff --check`: clean.
- `scripts/build-ipa-xtool.sh --clean` succeeded with the pinned Swift 6.4.2
  and xtool 1.24.0 after the 9.7.10 port, producing the repacked unsigned
  `xtool/GoldenNuggetMobile.ipa` (16.4 MB). Only pre-existing warnings were
  reported (`PosterKitStaging.swift:210`, `MediaView.swift:141`).
- The `xcrun`-based gates (`check-hotload.py`, `check-tunnel-endpoint.py`,
  `check-desktop-sync.py`, `tweak-port-diff.py`, `reset-port-diff.py`,
  `typecheck.sh`) still cannot run on this Linux host because `xcrun` is
  unavailable. Installing the pinned Swift 6.4.2 toolchain resolved the
  earlier `swift -print-target-info` failure in the xtool build.

Desktop-only Qt UI, translations, Python workers and device-management code stay
outside the port. Physical-device restore, pairing and SpringBoard rendering
still need hardware verification.

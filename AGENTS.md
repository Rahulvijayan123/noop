# Working in this repository

**Layer 1 + Watchdog are in this tree.** Read [docs/PORT_LAYER1_WATCHDOG.md](docs/PORT_LAYER1_WATCHDOG.md) before changing their scoring (and [docs/FRWHOOP_WATCHDOG_04_OCT_2026.md](docs/FRWHOOP_WATCHDOG_04_OCT_2026.md) if present). Source engines also live in the sibling checkout `/Users/chinmaydudi/Desktop/FRWHOOP/FRWHOOP_v2`.

Start with [README.md](README.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

- **The Xcode project is generated.** Run `xcodegen generate` after adding or removing files or
  editing `project.yml`. `Strand.xcodeproj/project.pbxproj` is gitignored; never commit it.
- **Build and test** with the commands in [docs/IOS.md](docs/IOS.md). The macOS `StrandTests` run is
  the main test suite.
- **The app and the worker share `Packages/StrandAnalytics`.** A scoring change affects both, so
  rebuild and redeploy the worker ([deploy/README.md](deploy/README.md)) when you change it.
- **Backend changes** go in `supabase/`. Never run `supabase db push` against production; follow the
  migration steps in [docs/BACKEND.md](docs/BACKEND.md).
- **Keep the internal NOOP and Strand names** for bundle IDs, the App Group, Keychain items,
  `noop.`-prefixed preference keys and the `OpenWhoop` data folder. Existing installs find their
  data through them. User-facing text says Nara.
- **Never commit secrets**: `Config/*Secrets.xcconfig`, `.env` files, database URLs, ingest tokens,
  B2 keys or the worker's `worker.env`.
- **Keep the licence files** (`LICENSE`, `NOTICE`, `ATTRIBUTION.md`, `DISCLAIMER.md`, `TERMS.md`).
  The licence is PolyForm Noncommercial 1.0.0.

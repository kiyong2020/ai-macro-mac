# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

macOS automation app (AppKit + Swift) that drives a golf-reservation web flow by replaying scripted UI actions: clicks, key presses, screen-capture-driven OCR matching.

## Build / Run

CocoaPods project — always open the workspace, never the bare `.xcodeproj`.

```sh
pod install                                    # first time / after Podfile change; Pods/ is gitignored
open AIMacro.xcworkspace                       # primary workspace
xcodebuild -workspace AIMacro.xcworkspace \
           -scheme AIMacro -configuration Debug -quiet build
```

- Workspace: `AIMacro.xcworkspace`. Schemes: `AIMacro` and `AIMacro_debug`. Target/product: `AIMacro` / `AIMacro.app`. Bundle id: `com.minseyesoft.aimacro`.
- Deployment target: AIMacro target is **macOS 14.6** (project-level default is 15.5). Code may freely use macOS 14 APIs (e.g. `SCScreenshotManager`). `CGWindowListCreateImage` is obsoleted in the macOS 15 SDK — do not introduce new calls; use `ActionDetailBuilder.captureRectAsync` for one-shot screenshots.
- Podfile pins `platform :osx, '12.0'` and a `post_install` hook forces every pod to MACOSX_DEPLOYMENT_TARGET=12.0 — necessary because RxSwift otherwise defaults to 10.9 and fails to compile against newer `Date`/`Data` APIs. Do not remove that hook. (The 12.0 number applies only to pods; the app itself targets 14.6.)
- The project was renamed from `GolfReservation` → `AIMacro` (target was previously `GolfReservation3`, productName was `MyApp`). If you find any lingering old references in code or config, those are oversights — clean them up.
- No XCTest target exists. There is no test command.

At first launch the app requests three permissions (granted via System Settings, not re-prompted): Accessibility (CGEventTap), Screen Recording (ScreenCaptureKit), Apple Events (for Chrome AppleScript). Without these the runner silently no-ops most action types.

## Runtime data location

`~/Library/Application Support/AIMacro/`

- `scenarios.json` — user-editable scenarios (managed by `ScenarioStore`).
- `actions.sqlite3` — per-action edited values keyed by stable action UUID (managed by `ActionStore`, replaces a prior UserDefaults flow).
- `snapshots/{action-id}.png` — OCR scan-area thumbnails (`OCRSnapshotStore`).

`AppDelegate.migrateLegacyAppSupportIfNeeded()` runs first thing in `applicationDidFinishLaunching` and moves an existing legacy `…/GolfReservation/` folder over to `…/AIMacro/` — it must run before any storage singleton is touched, so don't reorder it. The migration is one-shot (no-op once `AIMacro/` exists). When debugging persistence issues, inspect/clear these files rather than `defaults delete`.

## Architecture

The app is a single `NSWindow` storyboard UI (`Base.lproj/Main.storyboard` → `ViewController`) that edits and runs lists of `AutoAction`s. The execution engine is decoupled from the UI.

```text
AppDelegate
  ├─ requests permissions, wires status-bar item, connects SocketService
  └─ ViewController (Controllers/)
       ├─ owns: GlobalKeyListener, MouseListener, AutomationRunner,
       │        ActionCellFactory, ActionDetailBuilder
       ├─ left pane:  NSTableView of AutoActions in the selected Scenario
       ├─ right pane: detail form rebuilt per-selection by ActionDetailBuilder
       └─ Run button → AutomationRunner.run([AutoAction])
```

Key boundaries:

- **`AutoAction` (Automation/)** — the unit of work. Has a stable UUID `id` (DB key), an `ActionType` enum (`.click / .scroll / .key / .wait(.click|.enter|.code|.time) / .ocr / .script / .setURL / .openChrome / .windowFrame`), and per-field `BehaviorSubject`s (point/delay/count/text) so the detail UI binds reactively. JSON encoding lives on the action itself (`toFullJSON` / `fromFullJSON`); `Scenario` just maps over its actions. Legacy serialised shapes (e.g. `{"kind":"key","keyType":"enter|tab|scroll"}`) are migrated on load via `LegacyKeyType` — keep the migration when changing the format.
- **`Scenario` + `ScenarioStore`** — a named ordered list of `AutoAction`s, persisted as JSON. Adding/renaming/removing scenarios posts `ScenarioStore.didChangeNotification`; per-action *value* edits go through `ActionStore` instead and don't trigger that notification. On first launch, defaults are seeded from hardcoded arrays in `Core/Constants.swift` (`seonam`, `seonamFull`, `yangchun`, `test`).
- **`ActionStore`** — SQLite (`SQLite.swift`) keyed by `AutoAction.id`. `save()` / `restore()` on `AutoAction` are the only callers; do not introduce a parallel persistence path.
- **`AutomationRunner` (Automation/)** — the execution engine. Owns `MouseListener`, `GlobalKeyListener`, `ScreenCapturer`. Exposes RxSwift `BehaviorSubject`s (`currentIndex`, `totalCount`, `currentName`, `lastError`) that the view controller binds for the progress UI. Per-action errors are surfaced via `lastError` but **don't abort the sequence** — this is intentional. Each action's `delay` is applied *before* the action runs (changed from after); an optional uniform jitter from `Preferences.maxRandomDelay` is added on top.
- **Lifecycle signal:** Before any run starts, `AutomationRunner` posts `Notification.Name.actionSequenceWillStart` (defined in `App/Notifications.swift`). `SocketService` listens for it to drop the previously received SMS code, and `KeyUtil` clears its cache. When adding new per-run state, hook this notification rather than threading a callback through `ViewController`.
- **`SocketService` (Services/)** — Socket.IO client (server URL + username from `UserDefaults`, defaults from `Constants.defaultServerURL`). Exposes `receivedCode: BehaviorSubject<String>` which `runner.runWaitCode` awaits. Connection is initiated from `AppDelegate.applicationDidFinishLaunching`.
- **`ScreenCapturer` (Services/)** — ScreenCaptureKit-based. Used both for the live position-picker preview (`showsCursor=true`) and for OCR (`showsCursor=false`). Tracks `pendingStop` so a Stop-then-Run cycle waits for full SCStream teardown — without this the new stream silently delivers no frames. Don't remove that wait.
- **OCR action** — captures a fixed-size square (`Constants.ocrCaptureSize = 200pt`) centred on the action's point, runs Vision text recognition, and clicks the recognised word matching `action.text`. The target word is registered as a Vision custom word so it's preferred over visually-similar matches. `OCRDebugWindow` (Views/) renders a floating overlay; gated globally by `Constants.showOCRDebugWindow`.
- **Input listeners (Input/)** — `GlobalKeyListener` uses a `CGEventTap` at session level to surface global key events as a `BehaviorSubject<(Int, Bool)>`. `MouseListener` captures cursor position for the position-picker UI. `KeyUtil` translates `:enter / :space / :tab / ...` plus modifier prefixes (the `text` field of `.key` actions) into key codes.
- **Browser actions** — `.openChrome(url:)` / `.setURL(url:)` are dispatched to Google Chrome via AppleScript (`NSAppleScript`). They require the Apple Events permission requested at launch.
- **Preferences** — only `Preferences.maxRandomDelay` (jitter ceiling) and `Preferences.lastScenarioId` (restore last selection by UUID, not index, so renames don't break it) are first-class. Other settings (`serverURL`, `userName`) live directly on `SocketService` against `UserDefaults`.
- **View construction** — most detail forms and list cells are built programmatically (`ActionDetailBuilder`, `ActionCellFactory`, `ActionListCellView`, `ScanPreviewPanel`, `OCRDebugWindow`); only the top-level window/menu lives in the storyboard. `ViewController` rebuilds the detail pane per selection and uses a fresh `DisposeBag` (`detailBag`) so old bindings don't leak.

## Conventions

- Reactive state is RxSwift `BehaviorSubject`s on long-lived owners (actions, runner, services). UI subscribes through per-scope `DisposeBag`s — `disposeBag` for view-lifetime, `actionsBag` for current-scenario, `detailBag` for current-selection.
- Korean strings appear in user-facing labels, log messages, and `Constants` action names. Preserve them verbatim when refactoring.
- `AppLogger.shared.log(...)` is the in-app log sink (mirrored to the bottom log text view). Prefer it over `print` for anything the user might need to see.

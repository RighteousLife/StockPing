# StockPing

<p align="center">
  <img src="SwiftStockMonitor/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" alt="StockPing Icon" width="128" height="128" />
</p>

<p align="center">
  <strong>Native macOS product stock monitor for Shopify and major fashion retailers.</strong><br />
  Track specific products, colors, and sizes in the background and get notified when an unavailable variant comes back in stock.
</p>

<p align="center">
  <a href="#supported-stores">Stores</a> •
  <a href="#core-features">Features</a> •
  <a href="#architecture">Architecture</a> •
  <a href="#provider-integrations">Provider Integrations</a> •
  <a href="#reliability-and-stock-safety">Reliability</a> •
  <a href="#building-from-source">Build & Test</a> •
  <a href="#licensing">Licensing</a>
</p>

---

## Overview

**StockPing** is a native macOS application written in Swift and SwiftUI for monitoring product availability on supported retailer websites.

Instead of repeatedly checking product pages manually, StockPing keeps a centralized background schedule, checks the selected product variant, records meaningful stock-state transitions, and can notify the user through native macOS notifications and local Mail.

The application is designed for long-running monitoring. Provider-specific website behavior is isolated behind a common checker interface, while scheduling, persistence, notifications, analytics, diagnostics, and organization remain shared across providers.

StockPing currently supports:

- **Shopify**
- **Zara Türkiye**
- **Bershka Türkiye**
- **Pull&Bear Türkiye**
- **H&M Türkiye**

---

## Supported Stores

| Provider | Market | Stock Integration | Variant Tracking | Fallback Strategy |
| :--- | :--- | :--- | :---: | :--- |
| **Shopify** | Global Shopify storefronts | Shopify product JSON / variant availability | Yes | Provider-specific |
| **Zara** | Türkiye | Storefront availability data | Yes | Provider-specific |
| **Bershka** | Türkiye | Storefront state / availability data | Yes | Provider-specific |
| **Pull&Bear** | Türkiye | In-session Inditex structured API | Yes | Structured API → DOM |
| **H&M** | Türkiye | In-session OFG availability API | Yes | OFG API → SSR data → JSON-LD → DOM |

Provider implementations are intentionally isolated. Adding or changing a retailer should not require moving retailer-specific logic into the central scheduler or notification engine.

---

## Core Features

### Background Monitoring

- Centralized monitoring scheduler
- Per-product checking intervals
- Adaptive monitoring intervals
- Failure backoff after repeated check failures
- Network-aware checking and wake/recovery handling
- Configurable power/sleep-prevention modes
- Pause and resume individual products
- Priority products
- Scheduled monitoring windows
- Safe cancellation and stale-completion protection

### Variant-Level Tracking

StockPing can track a specific retailer variant instead of only a generic product page.

Depending on the provider, a tracked variant may include:

- Color
- Size
- SKU
- Article / product identifier
- Provider-specific variant identifier
- Provider-specific metadata

For providers exposing structured variant information, StockPing also maintains a **variant stock snapshot** so the user can see the current state of multiple colors and sizes.

---

## Notifications

### Native macOS Notifications

StockPing integrates with macOS notifications and can open the tracked product page directly from a notification.

### Local E-mail Notifications

Optional e-mail notifications are generated through the local macOS Mail workflow rather than a cloud SMTP service.

### Notification Profiles

Each tracked product can use one of four notification profiles:

| Profile | Restock | Depletion | Other Changes |
| :--- | :---: | :---: | :---: |
| **Standard** | Yes | No | No |
| **Only Restock** | Yes | No | No |
| **All Changes** | Yes | Yes | Yes |
| **Silent** | No | No | No |

Additional notification controls include per-channel enable/disable settings, notification auditing, and optional automatic opening of the product page after a restock.

---

## Stock Safety

StockPing deliberately separates **the stock state** from **the success of the check**.

A provider is not allowed to convert an API, network, WebKit, or parsing failure into an out-of-stock result.

The core semantic model is:

```text
Successful check + available       → true
Successful check + unavailable     → false

API / network / WebKit failure     → error / preserve last valid state
Variant not found                  → provider error
Ambiguous / unknown state          → unknown
```

### Restock Invariant

A restock notification is generated only for a real:

```text
false → true
```

transition.

The following do not create a false restock alert:

- Initial `nil → true` observation
- Unchanged `true → true`
- Unchanged `false → false`
- Temporary check failures
- Network outages
- WebView failures
- `true → false` depletion events

This invariant is handled centrally so every provider follows the same notification semantics.

---

## Architecture

StockPing uses a centralized, provider-isolated monitoring pipeline:

```text
┌───────────────────────────┐
│       TrackedProduct      │
│ URL + Selected Variant    │
│ Provider Metadata         │
└─────────────┬─────────────┘
              │
              ▼
┌───────────────────────────┐
│     Central Scheduler     │
│ Intervals / Adaptation    │
│ Backoff / Network Guard   │
└─────────────┬─────────────┘
              │
              ▼
┌───────────────────────────┐
│    StoreCheckerRouter     │
└─────────────┬─────────────┘
              │
     ┌────────┼──────────┬────────────┐
     ▼        ▼          ▼            ▼
 Shopify    Zara     Bershka      Pull&Bear
                                      │
                                      └──── H&M
              │
              ▼
┌───────────────────────────┐
│    Provider Checker       │
│ API / WebKit / Fallback   │
└─────────────┬─────────────┘
              │
              ▼
┌───────────────────────────┐
│     StoreCheckOutcome     │
│ Target State              │
│ Variant Snapshots         │
│ Diagnostics               │
└─────────────┬─────────────┘
              │
              ▼
┌──────────────────────────────────────┐
│     Central Stock Transition Logic   │
└───────┬──────────┬──────────┬────────┘
        │          │          │
        ▼          ▼          ▼
     History   Notifications  Analytics
                  │
          ┌───────┴────────┐
          ▼                ▼
        macOS             Mail
```

### Design Principles

**Centralized scheduling.** Providers answer stock questions; the central scheduler decides when products are checked.

**Provider isolation.** Retailer-specific API formats, identifiers, WebKit behavior, and fallbacks stay inside the provider.

**Fail-safe state handling.** Failed checks never become false stock readings.

**Persistence first.** Tracked products and provider metadata are persisted so monitoring can resume after application restarts.

**Native macOS behavior.** The application uses SwiftUI/AppKit/WebKit and native macOS services instead of requiring a browser extension or a cloud monitoring service.

---

## Provider Integrations

### Shopify

Shopify storefronts expose product/variant availability through storefront product data.

StockPing identifies the selected variant and reads its availability directly instead of relying on visible "Unavailable" text rendered in the page.

### Zara Türkiye

The Zara provider uses retailer-specific product and availability data and stores provider metadata required to identify a selected color/size variant reliably.

### Bershka Türkiye

The Bershka provider performs retailer-specific state validation and preserves its own product/color/size identifiers rather than using generic URL matching.

### Pull&Bear Türkiye

Pull&Bear uses a more defensive approach because direct requests may encounter Akamai bot protection.

The current provider uses:

```text
WKWebView session
      │
      ▼
In-session structured Inditex API
      │
      ├── real SKU / partnumber matching
      │
      ▼
DOM fallback
```

The structured API is preferred because it provides richer product, color, size, and availability information. The DOM path is retained as a fallback when the structured request cannot be used.

### H&M Türkiye

H&M uses a hybrid WebKit-based strategy:

```text
WKWebView
   │
   ▼
OFG availability API
   │
   ├── __NEXT_DATA__ SSR availability
   │
   ├── JSON-LD
   │
   └── DOM size selector
```

The provider uses real H&M variant identifiers and maintains article/color/size metadata for reliable matching.

The production H&M checker has been validated against live H&M Türkiye pages, including API success, fallback paths, out-of-stock products, and missing-variant safety behavior.

---

## Reliability and Stock Safety

StockPing is designed for continuous monitoring rather than one-off scraping.

Reliability work includes:

- WKWebView process-termination recovery
- Cancellable monitoring sequences
- Stale completion protection
- Central scheduler ownership
- Adaptive monitoring tiers
- Failure backoff
- Network reachability and recovery handling
- Cache maintenance for long-running WebKit sessions
- Provider-specific diagnostics
- Provider health summaries
- Structured retailer-specific fallback chains

### Failure Classification

Provider failures are kept separate from legitimate stock states.

Examples include:

- Network unavailable
- Provider failure
- Timeout
- Page load failure
- WebKit/JavaScript failure
- Variant not found
- Unknown/ambiguous stock state

This allows the application to preserve the last known valid stock state instead of generating false "sold out" transitions.

---

## Monitoring Controls

StockPing provides common controls independent of retailer:

| Capability | Description |
| :--- | :--- |
| **Interval** | Configure how frequently an individual product is checked |
| **Adaptive Monitoring** | Adjust monitoring cadence based on recent behavior |
| **Failure Backoff** | Reduce pressure on unhealthy providers or unreachable products |
| **Pause** | Temporarily stop checking a product without deleting it |
| **Priority** | Give selected products priority in monitoring organization |
| **Schedules** | Restrict monitoring to configured time windows |
| **Network Guard** | Avoid unnecessary checks while connectivity is unavailable |
| **Power Modes** | Control macOS sleep behavior while monitoring is active |
| **Auto-open** | Open the product page after a restock under configured rules |

The monitoring engine remains provider-agnostic: the same controls apply to Shopify, Zara, Bershka, Pull&Bear, and H&M products.

---

## Organization, History, and Analytics

StockPing is more than a stock checker; it maintains a local history of the tracked products.

### Organization

- Product groups
- Tags
- Notes
- Manual ordering
- Search and filtering
- Priority products

### History

Meaningful product events are recorded locally, including stock transitions and monitoring-related events. Product event history is bounded to the most recent 50 events per product.

### Analytics

Per-product stock analytics include:

- Stock-state statistics
- Availability behavior
- 7-day metrics
- 30-day metrics
- 90-day metrics
- Current variant stock summaries

### Provider Health

The Provider Health Center summarizes:

- Number of tracked products
- Active products
- Recent successful checks
- Recent provider failures
- Network availability
- Last known diagnostic information

---

## Variant Stock View

For providers that support multiple variants, StockPing can maintain a live snapshot of the discovered variants.

Example conceptual view:

```text
Color: Black
 ├── XS   ✓ In Stock
 ├── S    ✓ In Stock
 ├── M    ✕ Out of Stock
 └── L    ? Unknown

Color: Navy
 ├── XS   ✕ Out of Stock
 ├── S    ✓ In Stock
 └── M    ✓ In Stock
```

The underlying model distinguishes:

- `inStock`
- `outOfStock`
- `unknown`

so incomplete data can be surfaced without corrupting the central stock state.

---

## Diagnostics

Every provider can contribute diagnostic information used by the application to explain why a check succeeded or failed.

Diagnostics can include:

- Provider
- Checker
- Duration
- Outcome
- Stock result
- Network state
- Error category
- User-facing explanation
- Technical detail
- Last successful check

Technical diagnostic output is sanitized before it is presented to the user.

---

## Persistence and Backup

Tracked products are persisted locally using the application's versioned storage model.

Provider-specific metadata is preserved alongside the tracked product, including retailer-specific identifiers needed to continue checking the same variant after an application restart.

StockPing also supports JSON backup and restore.

Backup data includes product configuration, organization data, notification settings, event history, and provider metadata.

---

## macOS Integration

StockPing uses native macOS facilities for its desktop experience:

- SwiftUI application UI
- AppKit integration
- WebKit / WKWebView
- UserNotifications
- ServiceManagement
- Network framework
- Menu Bar Extra
- Native Settings
- Launch at Login
- Local Mail automation

Closing the main window hides the application rather than terminating background monitoring.

---

## Project Structure

The repository intentionally keeps provider logic separate from common application logic.

```text
StockPing/
├── SwiftStockMonitor.xcodeproj
│
├── SwiftStockMonitor/
│   ├── SwiftStockMonitorApp.swift
│   ├── ProductModels.swift
│   ├── StoreChecker.swift
│   ├── ShopifyChecker.swift
│   ├── ZaraChecker.swift
│   ├── BershkaChecker.swift
│   ├── PullAndBearChecker.swift
│   ├── HMChecker.swift
│   ├── ProductEvents.swift
│   ├── ProductBackupService.swift
│   ├── ProductOrganizationStore.swift
│   ├── NotificationAuditLog.swift
│   ├── EmailNotificationService.swift
│   ├── SleepPreventionManager.swift
│   └── Assets.xcassets/
│
├── SwiftStockMonitorTests/
│   └── HMCheckerTests.swift
│
├── AGENTS.md
├── LICENSE
└── README.md
```

---

## Building from Source

### Current Development Environment

The current application has been developed and validated on:

- **macOS:** 27
- **Architecture:** Apple Silicon / arm64
- **Swift:** 6.4
- **Xcode:** 27.0

Exact minimum OS/toolchain requirements have not been formally frozen yet.

### Build

Open the project in Xcode:

```bash
open SwiftStockMonitor.xcodeproj
```

Build the application from the **SwiftStock Monitor** scheme.

### Command-Line Verification

Debug build:

```bash
xcodebuild -scheme "SwiftStock Monitor" -configuration Debug build
```

Release build:

```bash
xcodebuild -scheme "SwiftStock Monitor" -configuration Release build
```

Test-target build:

```bash
xcodebuild -target SwiftStockMonitorTests -configuration Debug build
```

The repository also contains deterministic verification tooling used during provider and architecture hardening.

---

## Verification Status

The current project state has undergone repeated provider and architecture validation.

### Current verification snapshot

- **Deterministic verification:** 432 / 432 tests passing
- **SwiftStockMonitorTests target:** Builds successfully
- **Debug build:** PASS
- **Release build:** PASS
- **Installed Release application:** verified after the latest H&M integration work
- **H&M live provider validation:** PASS for production checker paths
- **Pull&Bear live fallback validation:** PASS
- **Stock transition safety:** PASS
- **Provider routing / cross-feature H&M audit:** PASS

The project has also been validated for common monitoring concerns such as provider failures, network outages, persistence, scheduler behavior, notifications, and variant matching.

> **Note:** Some live WebKit/XCTest scenarios require an active macOS GUI session. Headless command-line environments can prevent WebKit WebContent processes from starting even when the application itself builds correctly. Such cases are reported as untested rather than being treated as successful live tests.

---

## Data and Privacy Model

StockPing is a local macOS monitoring application.

Tracked products, settings, event history, provider metadata, analytics, and backups are stored locally by the application.

Retailer websites are necessarily contacted when a product is checked. Provider implementations may use the retailer's own website/API endpoints and, where required, an in-session WKWebView.

StockPing does not require a hosted stock-monitoring backend for its core monitoring workflow.

---

## Known Limitations

### Retailer Websites Can Change

Stock monitoring depends on third-party retailer websites and APIs. Providers may require maintenance if a retailer changes its URL structure, API schema, anti-bot system, page markup, or authentication/session requirements.

### Anti-Bot Systems

Some retailers actively detect automated traffic. StockPing therefore uses WebKit sessions and provider-specific strategies where appropriate rather than assuming that a simple HTTP request is always sufficient.

### Availability Semantics

A retailer can expose more than one notion of availability. StockPing intentionally treats unknown or ambiguous responses separately from a confirmed out-of-stock state.

### Polling Frequency

Very aggressive polling can increase rate-limit or anti-bot risk. The scheduler's adaptive and failure-backoff behavior is intended to reduce unnecessary request pressure.

---

## Development Philosophy

StockPing follows a few strict rules when adding provider support:

1. **Prove the retailer's behavior before implementing the provider.**
2. **Prefer structured stock data over brittle text scraping.**
3. **Use real variant identifiers whenever possible.**
4. **Keep retailer-specific behavior isolated.**
5. **Treat failures as failures, not as "out of stock".**
6. **Preserve backward-compatible persistence.**
7. **Validate the production code path on live pages whenever the environment allows it.**
8. **Avoid broad refactors when a targeted provider change is sufficient.**

---

## License

This project is licensed under the **MIT License**. See [LICENSE](LICENSE) for the full text.

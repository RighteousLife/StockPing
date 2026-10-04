# StockPing

Native macOS product stock monitor for supported Shopify and fashion retailer storefronts, built with Swift and SwiftUI.

StockPing monitors selected product variants in the background and notifies you when an unavailable item becomes available again. The app is designed around a centralized scheduler, provider-specific stock checkers, resilient WebKit sessions, and strict stock-state safety so a failed check is never mistaken for an out-of-stock result.

---

## Supported Stores

StockPing currently supports:

- **Shopify** — Shopify storefront product/variant availability
- **Zara Türkiye**
- **Bershka Türkiye**
- **Pull&Bear Türkiye**
- **H&M Türkiye**

Provider logic is isolated behind `StoreCheckerRouter`, so retailer-specific API, WebKit, variant, and fallback behavior does not leak into the common monitoring system.

---

## Key Features

### Monitoring

- Centralized background scheduler
- Configurable per-product checking intervals
- Adaptive monitoring intervals
- Failure backoff
- Network reachability / wake guard
- Optional power-management modes to keep monitoring reliable
- Pause/resume monitoring per product
- Priority products
- Scheduled monitoring windows

### Variant Tracking

- Product and variant discovery
- Color × size variant selection where supported
- Provider-specific identifiers and metadata
- Variant-level stock snapshots
- Variant stock summaries
- Real retailer SKU / variant IDs where available

### Notifications

- Native macOS notifications
- Optional e-mail notifications through the local Mail workflow
- Notification profiles:
  - Standard
  - Only Restock
  - All Changes
  - Silent
- Restock notification on strict `false → true` transitions
- Optional automatic product-page opening on restock
- Notification audit history

### Organization & Analytics

- Product groups
- Tags
- Product notes
- Manual product ordering
- Stock history
- Stock statistics
- 7 / 30 / 90 day analytics
- Provider health overview
- Detailed provider diagnostics

### Backup & Persistence

- Local product persistence
- Backward-compatible provider metadata persistence
- JSON backup / restore
- Variant metadata preservation
- Event-history persistence

### macOS Integration

- Native SwiftUI interface
- Menu Bar Extra with live monitoring status
- Product and provider status summaries
- Deep links to tracked products
- Native Settings
- Launch-at-login support
- Close-to-hide behavior while background monitoring continues

---

## Stock Safety

StockPing deliberately separates **stock state** from **check success**.

The core invariants are:

```text
Successful check + available        → true
Successful check + unavailable      → false

Network/API/WebKit failure          → error / preserve last valid state
Variant not found                   → error
Unknown / ambiguous state            → unknown
```

A failed check is never converted into `false`.

Restock notifications are generated only for a real:

```text
false → true
```

transition.

The initial check, unchanged states, transient failures, and `true → false` depletion events do not produce false restock alerts.

---

## Architecture

StockPing uses a centralized, provider-isolated monitoring pipeline:

```text
TrackedProduct
      │
      ▼
Central Scheduler
      │
      ▼
StoreCheckerRouter
      │
      ├── ShopifyChecker
      ├── ZaraChecker
      ├── BershkaChecker
      ├── PullAndBearChecker
      └── HMChecker
      │
      ▼
StoreCheckOutcome
  ├── target stock state
  ├── variant snapshots
  └── diagnostic information
      │
      ▼
Central Stock Transition Logic
      │
      ├── Event History
      ├── macOS Notification
      ├── E-mail Notification
      ├── Auto-open
      └── Analytics / Provider Health
```

Provider-specific integrations may use in-session WebKit APIs, structured retailer APIs, embedded page data, or DOM fallbacks depending on the retailer.

---

## Reliability

StockPing is built for long-running background monitoring rather than one-off product checks.

Current reliability work includes:

- WKWebView process-recovery handling
- stale completion protection
- cancellable monitoring sequences
- centralized scheduling
- failure backoff
- network-aware checking
- provider diagnostics
- structured fallback strategies
- provider-specific stock semantics
- persistent XCTest coverage for retailer-specific behavior

Recent provider work includes production validation of the Pull&Bear and H&M Turkey integrations against live retailer pages and stock responses.

---

## Technical Stack

- **Platform:** macOS
- **Architecture:** Apple Silicon / arm64
- **Language:** Swift
- **UI:** SwiftUI
- **Web:** WebKit / WKWebView
- **Frameworks:** AppKit, UserNotifications, ServiceManagement, Network
- **Build:** Xcode

---

## Project Structure

Provider-specific logic is intentionally isolated:

```text
SwiftStockMonitor/
├── StoreChecker.swift
├── ShopifyChecker.swift
├── ZaraChecker.swift
├── BershkaChecker.swift
├── PullAndBearChecker.swift
├── HMChecker.swift
├── ProductModels.swift
├── ProductBackupService.swift
├── NotificationAuditLog.swift
├── EmailNotificationService.swift
└── SwiftStockMonitorApp.swift
```

Tests for retailer-specific behavior live under:

```text
SwiftStockMonitorTests/
```

---

## Current Status

The repository currently contains the completed StockPing monitoring architecture and the production-integrated provider set listed above.

The latest releases of the retailer integrations were validated with deterministic regression tests, provider-specific tests, Debug/Release builds, and live retailer checks where the environment allowed them.

---

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

# StockPing

Native macOS product stock monitor for Shopify, Zara, Bershka, and Pull&Bear.

StockPing is a lightweight, session-grounded macOS application written in Swift and SwiftUI. It continuously monitors product availability on supported retailer websites and delivers instant macOS notifications when out-of-stock items become available.

---

## Supported Stores

StockPing currently supports real-time availability tracking for:

- **Shopify** (Global Shopify storefronts via storefront endpoints)
- **Zara** (Zara Turkey via storefront availability endpoints)
- **Bershka** (Bershka Turkey via storefront state validation)
- **Pull&Bear** (Pull&Bear Turkey via size-list DOM detection)

---

## Key Features

- **Automated Background Checking:** Configurable check intervals per product (from 1 minute to 24 hours).
- **Native macOS Notifications:** Instant notifications with direct product links when stock is replenished.
- **Strict Stock Transition Invariant:** Notifications fire strictly on `false → true` transitions (depleted → in stock). Initial checks, unchanged states, and transient check errors never trigger false restock alerts.
- **Event History:** Comprehensive history log tracking stock changes, recoveries, and monitoring events.
- **Menu Bar Extra:** Live stock summary, status overview, and manual trigger controls right from the macOS menu bar.
- **Close-to-Hide Architecture:** Red window close button hides the window without terminating background monitoring.

---

## Technical Stack

- **Platform:** macOS (Optimized for Apple Silicon / arm64)
- **Language:** Swift 6.0 (Complete Strict Concurrency)
- **Frameworks:** SwiftUI, AppKit, WebKit, UserNotifications, ServiceManagement
- **Build System:** Xcode

---

## Architecture

StockPing follows a strict, unidirectional single-source-of-truth pipeline:

```
TrackedProduct (URL & Variant)
      │
      ▼
Central Scheduler (ContentView)
      │
      ▼
StoreCheckerRouter
      │
      ▼
Provider-Specific Checker (Shopify / Zara / Bershka / Pull&Bear)
      │
      ▼
Stock Result (Bool: true / false)
      │
      ▼
Central Stock Transition Logic (StorePageWebView.Coordinator.transition)
      │
      ▼
Event History & macOS Notification
```

---

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

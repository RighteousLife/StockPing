# StockPing — Permanent AI Agent Guidelines & Development Rules

These instructions constitute the permanent, project-level development rules for any AI coding agent working on the **StockPing** codebase. All future development, refactoring, bug fixing, and feature additions must adhere to these principles.

---

## 1. Project Identity

StockPing is:
- A native macOS application written in **Swift** and **SwiftUI**.
- Built with **Xcode**, targeting **macOS** on **Apple Silicon (arm64)**.
- Designed with **WebKit** (`WKWebView`) where required for session-grounded, provider-specific stock checks.
- Application Name: **StockPing**
- Bundle Identifier: **com.swiftstock.monitor**

> [!IMPORTANT]
> Do NOT rename the application or bundle identifier unless explicitly requested by the user.

---

## 2. Core Architecture

The application strictly follows a unidirectional, single-source-of-truth pipeline:

```
TrackedProduct
      │
      ▼
Central Scheduler (ContentView / scheduleNextAutomaticCheck / startCheckSequence)
      │
      ▼
StoreCheckerRouter (StoreCheckerRouter.check / analyze)
      │
      ▼
Provider-Specific Checker (ShopifyChecker / ZaraChecker / BershkaChecker / PullAndBearChecker)
      │
      ▼
Stock Result (Bool: true = in stock, false = out of stock)
      │
      ▼
Central Stock Transition Logic (StorePageWebView.Coordinator.transition(from:to:))
      │
      ▼
History / macOS Notification (ProductEvent recording & StockNotificationManager)
```

Currently supported providers:
1. **Shopify** (Global Shopify stores via `/products/<handle>.js`)
2. **Zara** (Zara Turkey via `window.zara.viewPayload` & storefront availability API)
3. **Bershka** (Bershka Turkey via `window.__NUXT__.pinia.productDetail.currentProduct`)
4. **Pull&Bear** (Pull&Bear Turkey via DOM/Shadow DOM `SIZE-LIST` and selectable button states)

Provider-specific stock detection must remain provider-specific. Do not force all providers into an artificial single implementation.

---

## 3. Provider Checkers

Current provider checker modules:
- `ShopifyChecker`
- `ZaraChecker`
- `BershkaChecker`
- `PullAndBearChecker`

Each provider checker completely owns its provider-specific behavior:
- URL validation, normalization, and pattern recognition (`canHandle`, `normalizedProductURL`)
- Product catalog discovery and variant extraction (`analyze`)
- Variant identification (SKU, colorProductID, partnumber, color parameter)
- Real-time stock status detection (`check`)
- Provider-specific payload parsing
- Provider-specific variant metadata structures
- Provider-specific error types (`LocalizedError`)

Rules:
- Do NOT move provider-specific logic into unrelated shared components without a concrete, documented reason.
- Do NOT fabricate stock identifiers, SKUs, API endpoints, or availability semantics.
- If a provider's stock mechanism is uncertain, investigate it via browser inspection or read-only tools before modifying production logic.

---

## 4. Central Scheduler

StockPing uses a single, centralized scheduling engine inside `ContentView`:
- **Centralized Queue:** A single active sequential check queue (`isCheckSequenceRunning`) runs checks sequentially to prevent headless WebView overload.
- **Dynamic Scheduling:** Evaluates `nextCheckDate` across all non-paused products and sets a single timer to wake up for the earliest due check.
- **Per-Product Intervals:** Supports individual check intervals (1, 2, 5, 10, 30, 60, 120, 300, 720, 1440 minutes).
- **Control Features:** Preserves pause/resume (`isPaused`), manual single-check, and manual check-all.
- **Cleanup & Safety:** Manages timeouts, continuation resumptions, and queue cleanup on failure or cancellation.

Rules:
- Do NOT create independent timers per product unless explicitly requested and technically justified.
- Provider checkers must only return their stock result (`Bool`) or throw an error; never embed scheduler logic inside checker modules.

---

## 5. Stock Transition Logic

The central transition logic in `StorePageWebView.Coordinator.transition(from:to:)` is the sole authority for state transitions:

| Previous State (`previous`) | Current State (`current`) | Transition Result | Restock Event Triggered? | macOS Notification? |
| :---: | :---: | :---: | :---: | :---: |
| `false` (Out of Stock) | `true` (In Stock) | `.restocked` | **YES** (`.stockArrived`) | **YES** |
| `true` (In Stock) | `true` (In Stock) | `.unchanged(available: true)` | **NO** | **NO** |
| `false` (Out of Stock) | `false` (Out of Stock) | `.unchanged(available: false)` | **NO** | **NO** |
| `true` (In Stock) | `false` (Out of Stock) | `.wentOutOfStock` | **NO** (`.stockDepleted`) | **NO** |
| `nil` (First Successful Check) | `true` or `false` | `.initial(available: current)` | **NO** | **NO** |
| Any State | **Error / Timeout** | Throws error | **NO** (`.checkFailed`) | **NO** |

Rules:
- A real restock event is strictly `false → true`.
- First successful check (`nil → true` or `nil → false`) is an initialization event, NEVER a restock event.
- Check errors, timeouts, and cancellations must NEVER trigger a restock event.
- Do NOT duplicate stock transition logic inside provider checkers, notification handlers, email dispatchers, or UI views.

---

## 6. Notifications

- Notifications are triggered exclusively from confirmed central `.restocked` events.
- Provider checkers must never directly invoke notification APIs.
- A notification failure (e.g. system permission denied) must never mark a successful stock check as failed.
- The notification subsystem must never modify product stock state.

---

## 7. Persistence & Existing User Data

- **Storage Engine:** `UserDefaults.standard` with storage key `"trackedProducts.v1"`.
- **Model:** `TrackedProduct` encoded via `SavedTrackedProduct` (Codable).
- **Backward Compatibility:** Preserves legacy fields (`variantID`, `variantTitle`, `lastKnownAvailable`, `options`, `status`) to ensure older saves load seamlessly.
- **Event Cap:** Product history (`events`) is capped at the 50 most recent events (`record(...)`).

Rules:
- Do NOT reset `UserDefaults` or wipe existing products.
- Do NOT silently delete product records or change persistence keys unnecessarily.
- Never perform destructive schema migrations without explicit user approval.
- Existing tracked products represent user data. Never remove, replace, or alter real products for testing.
- Do NOT automatically add demonstration or sample products into the user's product list.
- Do NOT reintroduce previously removed Taylor Swift vinyl test products.

---

## 8. UI & macOS Design System

- Built with native SwiftUI for macOS: split navigation (`NavigationSplitView`), native sidebars, menus, sheets, and toolbars.
- Use native controls, standard typography, and SF Symbols.
- Preserve existing interactive features:
  - Search field (`.searchable`)
  - Status filtering (`ProductListFilter`)
  - Sorting (`ProductListSort`: default, product name with Turkish locale, last checked, next check)
  - Multi-selection mode (`isSelectionMode`), checkboxes, and batch deletion with confirmation
  - Product detail panel with live relative time countdowns (`TimelineView`)
  - Disclosure groups for product metadata and event history
  - Menu bar extra (`MenuBarExtra`) with live status summary, window focus, check-all, and quick quit
  - Close-to-hide window behavior (`CloseToHideWindowDelegate` keeping app alive when red close button is pressed)
  - Notification click routing to browser (`UNUserNotificationCenterDelegate`)
- Do not introduce unrelated design frameworks or redesign screens without explicit user request.

---

## 9. Accessibility

- Do not rely solely on color to communicate stock status; always pair colors with distinct symbols and descriptive text badges.
- Maintain accessibility labels, hints, and values on custom interactive elements.
- Preserve full keyboard navigation and existing shortcuts (`Cmd+N`, `Cmd+R`, `Cmd+Shift+R`, `Backspace`).

---

## 10. Settings Architecture

- Integrated via native SwiftUI `Settings` scene and `SettingsView`.
- Configured with `@AppStorage` keys (`automaticCheckingEnabled`, `checkIntervalMinutes`, `stockNotificationsEnabled`, `launchAtLoginEnabled`).
- Launch-at-login is driven by Apple's `ServiceManagement` (`SMAppService.mainApp`).
- All settings must use clear Turkish labels and sensible defaults, taking effect immediately when practical.
- Do not create detached custom settings windows for individual features.

---

## 11. Error Handling & Timeout Protections

- Clearly distinguish between **Stock-Check Failures** and **Secondary Subsystem Failures** (e.g. notifications, audio, UI updates).
- A secondary failure must never cause a product status to flip to `Kontrol hatası` (`ProductStatus.error`).
- Preserve the last-known valid stock state when a check fails; do not convert an error or timeout into an out-of-stock (`false`) state.
- Preserve all existing timeout gates:
  - WebView readiness timeouts (Shopify: 15s, Bershka: 30s, Zara / Pull&Bear: 40s)
  - Provider safety timeout (40s fallback in `StorePageWebView.Coordinator`)
  - JavaScript abort controllers and execution timeouts (e.g. Pull&Bear 5s JS gate, Shopify 10s fetch gate)
- Every asynchronous operation must provide a guaranteed completion path (`continuation.resume`) to prevent queue deadlocks.

---

## 12. Web & Retailer Provider Safety

- StockPing interacts with live third-party retailer web pages.
- Never assume that generic text like "Unavailable" or "Stokta Yok" on a page applies to the specific tracked SKU without verifying variant selection.
- Do not invent undocumented API endpoints or scrape arbitrary unverified HTML structures.
- If a retailer changes its web interface or data structure:
  1. Inspect the live page structure carefully.
  2. Pinpoint the exact breaking change.
  3. Implement the minimal, isolated provider fix.
  4. Verify against real URLs.
  5. Document any edge cases or limitations.

---

## 13. Refactoring Policy

- StockPing is an actively working application; do not refactor code merely for aesthetic reasons.
- Prioritize **minimal, targeted changes** over broad architectural rewrites.
- Refactoring is permissible only when:
  - Explicitly requested by the user.
  - Strictly required to enable a new feature.
  - Necessary to resolve a proven bug.
  - Meaningfully reducing verified complexity.
- Do NOT arbitrarily split or rewrite `SwiftStockMonitorApp.swift` unless instructed with an agreed plan.

---

## 14. Abstractions Policy

- Do not create generic, over-engineered abstractions merely because two retailers appear superficially similar.
- Each retailer has distinct bot mitigation, state management (Nuxt/Pinia vs React/Redux vs static DOM vs JSON endpoints), and viewport requirements (e.g. Pull&Bear desktop layout requirement).
- Keep provider implementations concrete, explicit, and self-contained.

---

## 15. Build & Target Environment

- Target platform: **macOS**, architecture **arm64** (Apple Silicon).
- When coding tasks complete, verify compilation using `xcodebuild` with the target `SwiftStock Monitor` and scheme `SwiftStock Monitor`.
- Never claim a build succeeded without executing and inspecting compiler output.
- Clearly distinguish between build failures, test failures, and environment/tooling issues.

---

## 16. Git & Version Control Rules

- Git is the absolute source of truth. Always inspect `git status` before and after changes.
- Never run destructive Git commands (`git reset --hard`, `git checkout -- .`, `git restore .`, `git clean -fd`) without explicit user consent.
- Commit only when explicitly requested by the user or when the task objective mandates committing.
- Commit messages must be clear, concise, and accurately describe the changes made.
- Do NOT push to GitHub or configure remote repositories unless explicitly instructed. Local development and GitHub publishing are separate steps.

---

## 17. Credential & Secret Protection

- NEVER commit secrets: API tokens, passwords, private keys, certificates, SMTP credentials, `.env` files, or cloud credentials.
- If a suspected secret is discovered in source or configuration files:
  - **STOP immediately before committing.**
  - Report the file and nature of the suspected credential without printing the secret value.

---

## 18. Verification & Reporting Standard

For every verification step, accurately distinguish:
- **PASS**: Verified and confirmed working.
- **FAIL**: Verified and failed.
- **NOT TESTED**: Not verified (with clear reason, e.g. environment limitation).

Never report an unverified item as PASS.

At the conclusion of each significant development task, provide a structured report with:
- **Changed:** Exact list of modified files.
- **Implemented:** What features/fixes were introduced.
- **Build:** Compiler results (`xcodebuild`).
- **Tests:** Verification outcomes (PASS / FAIL / NOT TESTED).
- **Regression:** Impact on unaffected providers and central components.
- **Git:** Status of the working tree.
- **Limitations:** Any known edge cases or deferred items.

---

## 19. User Workflow & Communication

- The user communicates in natural language and does not manually edit Swift code.
- The AI agent is responsible for locating relevant code, making minimal edits, verifying builds, and reporting results clearly.
- Always provide clickable GitHub-style links to files and symbols (`file:///...`).
- When a task conflicts with a general guideline, follow the user's specific instructions, isolate the impact, preserve unaffected areas, and clearly state the rationale in the report.

---

## 20. The Prime Directive

> **Preserve working behavior first.**  
> Change only what the requested feature requires.  
> Prefer small, reversible changes.  
> Verify before declaring success.  
> Never sacrifice working functionality for theoretical elegance.

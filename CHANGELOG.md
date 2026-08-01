# Changelog

## 0.1.1 - 2026-08-01

- Add an automatic iOS 16.4–18.x floating-pill fallback with a Swift spring
  selection capsule while retaining real UIKit tab items.
- Keep expanded and compact fallback geometry aligned with the iOS 26 layout,
  including centred legacy icons and home-indicator clearance.
- Reset newly selected tabs to their true adjusted visual top after navigation
  and reconcile late safe-area inset changes.
- Preserve animated active-tab reselect scrolling to the adjusted visual top.
- Document the difference between true iOS 26+ Liquid Glass, the older-iOS
  solid fallback, and the currently unsupported Android platform.

## 0.1.0

- Host a real standalone UIKit `UITabBar` from Expo.
- Keep every icon visible while compact by removing only item labels.
- Animate compact width and height with an interruptible native spring.
- Accept app-owned React Native image sources instead of bundled artwork.
- Play optional per-tab frame sequences natively and respect Reduce Motion.
- Restore active-tab reselect scrolling to UIKit's visual top in Expo Router.
- Export an isolated scroll-direction controller with rubber-band protection.

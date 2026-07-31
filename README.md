# expo-native-compact-tabs

A real UIKit tab bar for Expo apps that keeps every tab visible when it becomes
compact.

`expo-native-compact-tabs` hosts a standalone `UITabBar`, so iOS still owns the
Liquid Glass material, selection capsule, hit testing, and accessibility. Your
React Native navigator continues to own routes and screen lifecycle. Because
the bar is not managed by a `UITabBarController`, your app—not
`UITabBarMinimizeBehavior`—decides what compact means.

On iOS 26, this gives you Apple's actual Liquid Glass and water-drop selection
motion while allowing a compact state that removes labels but keeps every icon.
Earlier iOS versions receive the native UIKit appearance for that OS.

## Requirements

- Expo SDK 57 or newer
- React Native 0.86 or newer
- React Native Reanimated 4 or newer
- iOS 16.4 or newer
- A development build or production build; custom native modules do not run in
  Expo Go

## Install

```sh
npx expo install expo-native-compact-tabs react-native-reanimated
npx expo run:ios
```

After adding or upgrading the package, rebuild the native app. A Metro reload
cannot install Swift code into an existing binary.

## Expo Router example

Keep Expo Router's native tabs as the navigator, hide its system bar, and place
the standalone bar above it. First create one controller that the layout and
scrolling screens can share:

```tsx
// tab-controller.ts
import { createCompactTabBarController } from 'expo-native-compact-tabs';

export const tabBarController = createCompactTabBarController();
```

Then render the native control in the tab layout:

```tsx
import { router, usePathname } from 'expo-router';
import { NativeTabs } from 'expo-router/unstable-native-tabs';
import { View } from 'react-native';
import {
  NativeCompactTabBar,
  type NativeCompactTabBarItem,
} from 'expo-native-compact-tabs';
import { tabBarController } from './tab-controller';

const routes = ['/', '/search', '/saved'] as const;
const items: NativeCompactTabBarItem[] = [
  {
    key: 'home',
    label: 'Home',
    icon: require('./assets/home-0.png'),
    animationFrames: [
      require('./assets/home-0.png'),
      require('./assets/home-1.png'),
      require('./assets/home-2.png'),
    ],
  },
  {
    key: 'search',
    label: 'Search',
    icon: require('./assets/search.png'),
  },
  {
    key: 'saved',
    label: 'Saved',
    icon: require('./assets/saved.png'),
  },
];

export default function TabLayout() {
  const pathname = usePathname();
  const compact = tabBarController.useCompact();
  const selectedIndex = Math.max(routes.indexOf(pathname as (typeof routes)[number]), 0);

  return (
    <View style={{ flex: 1 }}>
      <NativeTabs hidden minimizeBehavior="never">
        <NativeTabs.Trigger name="index" />
        <NativeTabs.Trigger name="search" />
        <NativeTabs.Trigger name="saved" />
      </NativeTabs>

      <NativeCompactTabBar
        items={items}
        selectedIndex={selectedIndex}
        compact={compact}
        tintColor="#ff5a36"
        inactiveTintColor="#a7afbc"
        onTabSelected={({ nativeEvent }) => {
          tabBarController.expand();
          const href = routes[nativeEvent.index];
          if (href && href !== pathname) router.navigate(href);
        }}
        style={{
          position: 'absolute',
          left: 0,
          right: 0,
          bottom: 0,
          height: 78,
        }}
      />
    </View>
  );
}
```

Attach the controller's scroll handler to the first scroll view in each tab:

```tsx
import Animated from 'react-native-reanimated';
import { tabBarController } from './tab-controller';

export function Feed() {
  const { scrollRef, scrollY, onScroll } = tabBarController.useCollapsingScroll();

  return (
    <Animated.ScrollView ref={scrollRef} onScroll={onScroll} scrollEventThrottle={16}>
      {/* content */}
    </Animated.ScrollView>
  );
}
```

Create the controller once at module scope and export app-specific wrapper
hooks if multiple screens need it. Each controller owns an independent compact
state. Downward scrolling compacts after meaningful travel; upward scrolling or
returning near the top expands it. Rubber-band overscroll is ignored.

## Icon animation

`animationFrames` is optional. When supplied, the native view resolves and
caches the frames, then plays them once at 34 ms per frame on selection and
reselection. UIKit continues to draw the selected capsule throughout. Frame 0
is restored when playback finishes. iOS Reduce Motion disables frame playback.

Use local, equally sized PNGs with transparent backgrounds. Put the resting
image first. Keep the `items` array at module scope or memoize it so React does
not needlessly resolve the same sources again.

## Props

| Prop | Type | Default | Purpose |
| --- | --- | --- | --- |
| `items` | `NativeCompactTabBarItem[]` | required | Labels, icons, optional animation frames |
| `selectedIndex` | `number` | required | Controlled selected tab |
| `compact` | `boolean` | required | Removes labels and animates compact geometry |
| `tintColor` | `string` | system | Selected item tint |
| `inactiveTintColor` | `string` | system | Unselected item tint |
| `expandedHorizontalInset` | `number` | `12` | Host inset in expanded state |
| `compactWidth` | `number` | `352` | Compact host width; UIKit adds its own visual inset |
| `expandedHeight` | `number` | `78` | Expanded native host height |
| `compactHeight` | `number` | `70` | Compact native host height |
| `animationFrameDuration` | `number` | `0.034` | Seconds per icon frame |
| `onTabSelected` | event callback | — | Reports the tapped item index |

The component should normally be pinned to `bottom: 0`. `UITabBar` preserves
its own lower layout space for the home indicator, which avoids device-specific
safe-area guesses.

## Native behavior and limitations

- This is a visible native control, not a navigator. Route changes must be
  handled in `onTabSelected`, and `selectedIndex` must follow the active route.
- Active-tab reselect scrolls the selected Expo Router NativeTabs scroll view to
  `-adjustedContentInset.top`, matching UIKit's visual top rather than `y: 0`.
- Nested-stack pop-to-root behavior is not currently implemented.
- The compact geometry is intentionally controlled. Apple's
  `UITabBarMinimizeBehavior` only controls *when* the system minimizes and its
  built-in compact result keeps only the selected tab.
- The public API is iOS-only. Do not render the component on Android.

## Why a standalone UITabBar?

Custom React Native bars can reproduce the layout but not UIKit's exact Liquid
Glass selection capsule. A normal `UITabBarController` preserves that capsule
but owns the minimize policy. A standalone `UITabBar` is the useful seam: UIKit
still renders and interacts; React Native controls the frame, titles, routes,
and scroll policy.

## Publishing

Before a release:

```sh
npm run typecheck
npm pack --dry-run
npm publish --access public
```

Publishing is intentionally manual. Verify the packed file list, commit and tag
the release, then publish from a clean checkout.

## License

MIT

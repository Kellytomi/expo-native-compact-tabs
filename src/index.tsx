import { requireNativeViewManager } from 'expo-modules-core';
import { useMemo } from 'react';
import { Image } from 'react-native';
import type {
  ImageSourcePropType,
  NativeSyntheticEvent,
  ViewProps,
} from 'react-native';

export type NativeCompactTabBarItem = {
  /** Stable identity used to avoid rebuilding native items unnecessarily. */
  key: string;
  label: string;
  icon: ImageSourcePropType;
  /** One-shot frames played when this tab is selected or reselected. */
  animationFrames?: readonly ImageSourcePropType[];
  accessibilityLabel?: string;
};

export type NativeCompactTabBarSelectionEvent = NativeSyntheticEvent<{
  index: number;
}>;

export type NativeCompactTabBarProps = ViewProps & {
  items: readonly NativeCompactTabBarItem[];
  selectedIndex: number;
  compact: boolean;
  tintColor?: string;
  inactiveTintColor?: string;
  expandedHorizontalInset?: number;
  compactWidth?: number;
  expandedHeight?: number;
  compactHeight?: number;
  animationFrameDuration?: number;
  /**
   * Enables press-and-drag selection on Android and the pre-iOS 26 fallback.
   * iOS 26 continues to use UIKit's native Liquid Glass interaction.
   */
  selectionDragEnabled?: boolean;
  onTabSelected?: (event: NativeCompactTabBarSelectionEvent) => void;
};

type NativeItem = {
  key: string;
  label: string;
  imageUri: string;
  imageScale: number;
  animationFrameUris: string[];
  animationFrameScales: number[];
  accessibilityLabel?: string;
};

type NativeProps = Omit<NativeCompactTabBarProps, 'items' | 'compact'> & {
  items: NativeItem[];
  compact: boolean;
};

const NativeCompactTabBarView = requireNativeViewManager<NativeProps>(
  'ExpoNativeCompactTabs',
  'ExpoNativeCompactTabsView'
);

type ResolvedImage = {
  uri: string;
  scale: number;
};

function resolveImage(
  source: ImageSourcePropType,
  itemKey: string
): ResolvedImage {
  const resolved = Image.resolveAssetSource(source);
  if (!resolved?.uri) {
    throw new Error(
      `expo-native-compact-tabs could not resolve the icon for item "${itemKey}".`
    );
  }
  return {
    uri: resolved.uri,
    scale: resolved.scale ?? 0,
  };
}

/**
 * A native floating tab bar whose compact state retains every icon.
 * iOS uses a standalone `UITabBar`; Android uses a native Kotlin view.
 * Navigation remains controlled by the caller (for example, Expo Router).
 */
export function NativeCompactTabBar({
  items,
  compact,
  ...props
}: NativeCompactTabBarProps) {
  const nativeItems = useMemo(
    () =>
      items.map((item) => {
        const image = resolveImage(item.icon, item.key);
        const animationFrames = (item.animationFrames ?? []).map((frame) =>
          resolveImage(frame, item.key)
        );

        return {
          key: item.key,
          label: item.label,
          imageUri: image.uri,
          imageScale: image.scale,
          animationFrameUris: animationFrames.map((frame) => frame.uri),
          animationFrameScales: animationFrames.map((frame) => frame.scale),
          accessibilityLabel: item.accessibilityLabel,
        };
      }),
    [items]
  );

  return (
    <NativeCompactTabBarView
      {...props}
      items={nativeItems}
      compact={compact}
    />
  );
}

/** @deprecated Use `NativeCompactTabBar`. */
export const NativeTabBar = NativeCompactTabBar;
/** @deprecated Use `NativeCompactTabBarItem`. */
export type NativeTabBarItem = NativeCompactTabBarItem;

export {
  createCompactTabBarController,
  type CompactTabBarControllerOptions,
} from './scroll';

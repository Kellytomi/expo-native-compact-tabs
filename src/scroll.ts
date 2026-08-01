import { useEffect, useRef, useSyncExternalStore } from 'react';
import type { ScrollView } from 'react-native';
import {
  runOnJS,
  useAnimatedScrollHandler,
  useSharedValue,
} from 'react-native-reanimated';

export type CompactTabBarControllerOptions = {
  /** Directional travel required before compact state changes. */
  directionThreshold?: number;
  /** Offset before downward scrolling is allowed to compact the bar. */
  armAt?: number;
};

/**
 * Creates an isolated compact-state store and a Reanimated scroll handler.
 * The state is latched: it changes after meaningful directional travel, not
 * every pixel, and ignores rubber-band movement beyond the scrollable range.
 */
export function createCompactTabBarController({
  directionThreshold = 8,
  armAt = 28,
}: CompactTabBarControllerOptions = {}) {
  let compact = false;
  const listeners = new Set<() => void>();
  const scrollRefs = new Map<string, { current: ScrollView | null }>();
  const pendingScrolls = new Map<string, boolean>();

  function setCompact(next: boolean) {
    if (next === compact) return;
    compact = next;
    listeners.forEach((listener) => listener());
  }

  function subscribe(listener: () => void) {
    listeners.add(listener);
    return () => listeners.delete(listener);
  }

  function useCompact() {
    return useSyncExternalStore(subscribe, () => compact);
  }

  function expand() {
    setCompact(false);
  }

  /**
   * Scrolls a registered tab to its visual top. If the screen has not mounted
   * yet, the request is retained and applied when its keyed hook registers.
   */
  function scrollToTop(key: string, animated = true) {
    setCompact(false);
    const scrollView = scrollRefs.get(key)?.current;
    if (!scrollView) {
      pendingScrolls.set(key, animated);
      return false;
    }

    pendingScrolls.delete(key);
    scrollView.scrollTo({ y: 0, animated });
    return true;
  }

  /** Registers this scroll view for cross-tab reset when a stable key is given. */
  function useCollapsingScroll(key?: string) {
    const scrollRef = useRef<ScrollView>(null);
    const scrollY = useSharedValue(0);
    const anchor = useSharedValue(0);

    useEffect(() => {
      if (!key) return;
      scrollRefs.set(key, scrollRef);

      const pendingAnimated = pendingScrolls.get(key);
      let frame: number | undefined;
      if (pendingAnimated !== undefined) {
        frame = requestAnimationFrame(() => {
          pendingScrolls.delete(key);
          scrollRef.current?.scrollTo({ y: 0, animated: pendingAnimated });
        });
      }

      return () => {
        if (frame !== undefined) cancelAnimationFrame(frame);
        if (scrollRefs.get(key) === scrollRef) scrollRefs.delete(key);
      };
    }, [key]);

    const onScroll = useAnimatedScrollHandler({
      onBeginDrag: (event) => {
        const maxY = Math.max(
          event.contentSize.height - event.layoutMeasurement.height,
          0
        );
        anchor.value = Math.min(Math.max(event.contentOffset.y, 0), maxY);
      },
      onScroll: (event) => {
        const maxY = Math.max(
          event.contentSize.height - event.layoutMeasurement.height,
          0
        );
        const y = Math.min(Math.max(event.contentOffset.y, 0), maxY);
        scrollY.value = y;

        if (y <= armAt) {
          anchor.value = y;
          runOnJS(setCompact)(false);
          return;
        }

        const dy = y - anchor.value;
        if (dy > directionThreshold) {
          anchor.value = y;
          runOnJS(setCompact)(true);
        } else if (dy < -directionThreshold) {
          anchor.value = y;
          runOnJS(setCompact)(false);
        }
      },
    });

    return { scrollRef, scrollY, onScroll };
  }

  return { useCompact, expand, scrollToTop, useCollapsingScroll };
}

# Contributing

Thanks for helping improve `expo-native-compact-tabs`.

## Before opening an issue

- Search existing issues first.
- Use the bug form for reproducible defects and the feature form for proposals.
- Never report a security vulnerability in a public issue; follow
  [SECURITY.md](SECURITY.md) instead.

For visual or behavioral bugs, include:

- Expo, React Native, package, Xcode, and iOS versions.
- Simulator or physical-device model.
- Whether the issue occurs on iOS 26+ Liquid Glass, the iOS 16.4–18.x solid
  fallback, or both.
- A minimal reproduction and, when useful, a screenshot or recording.

## Development

```sh
npm install
npm run typecheck
```

This is a native Expo module. Swift changes require a development build; Expo
Go and a Metro reload cannot load newly compiled native code.

When testing native changes, verify:

- Expanded and compact states.
- Selection and reselection for every tab.
- Icon animation with Reduce Motion both enabled and disabled.
- Scroll-to-top behavior and destination-tab scroll reset.
- iOS 26+ and the iOS 16.4–18.x fallback when the change affects layout or
  appearance.

## Pull requests

1. Fork the repository and create a focused branch.
2. Keep the change small and explain the user-facing reason.
3. Add or update documentation when behavior or the public API changes.
4. Run `npm run typecheck` and `npm pack --dry-run`.
5. Complete the pull-request checklist.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

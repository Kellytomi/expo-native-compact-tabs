import ExpoModulesCore
import UIKit

public final class ExpoNativeCompactTabsView: ExpoView, UITabBarDelegate {
  private static let imageCache = NSCache<NSString, UIImage>()

  let onTabSelected = EventDispatcher()

  private let legacyBackgroundView = UIView(frame: .zero)
  private let legacySelectionView = UIView(frame: .zero)
  private let tabBar = UITabBar(frame: .zero)
  private var itemDefinitions: [ExpoNativeCompactTabItem] = []
  private var animationFrames: [[UIImage]] = []
  private var selectedIndex = 0
  private var isCompact = false
  private var collapseAnimator: UIViewPropertyAnimator?
  private var legacySelectionAnimator: UIViewPropertyAnimator?
  private var iconAnimationTimer: Timer?
  private var animatingIndex: Int?
  private var animationFrameIndex = 0
  private var imageLoadGeneration = UUID()

  var expandedHorizontalInset: CGFloat = 12 {
    didSet { setNeedsLayout() }
  }

  var compactWidth: CGFloat = 352 {
    didSet { setNeedsLayout() }
  }

  var expandedHeight: CGFloat = 78 {
    didSet { setNeedsLayout() }
  }

  var compactHeight: CGFloat = 70 {
    didSet { setNeedsLayout() }
  }

  var animationFrameDuration: TimeInterval = 0.034

  var tabTintColor: UIColor? {
    didSet { tabBar.tintColor = tabTintColor }
  }

  var inactiveTabTintColor: UIColor? {
    didSet { tabBar.unselectedItemTintColor = inactiveTabTintColor }
  }

  public required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)

    backgroundColor = .clear
    clipsToBounds = false

    tabBar.delegate = self
    tabBar.isTranslucent = true
    tabBar.itemPositioning = .fill
    tabBar.backgroundColor = .clear

    if #available(iOS 26.0, *) {
      tabBar.clipsToBounds = false
    } else {
      configureLegacyAppearance()
      addSubview(legacyBackgroundView)
      // A CHILD of the pill, not a sibling. As siblings the two were each
      // positioned in the parent's coordinates by different animators, and the
      // capsule could be left describing the expanded surface while the pill
      // had already become compact — it drew ~7pt low, which is exactly the
      // gap between the two surfaces' centres. Parented, it cannot disagree.
      legacyBackgroundView.addSubview(legacySelectionView)
    }
    addSubview(tabBar)
  }

  deinit {
    iconAnimationTimer?.invalidate()
  }

  /// Pre-26 only: hide the safe area from the standalone `UITabBar`.
  ///
  /// UIKit reserves "lower layout space" wherever the bar overlaps the home
  /// indicator and parks the item content above it. Our pill floats clear of
  /// the indicator already, so that reservation shows up as ~17pt of dead
  /// space along the bottom of the pill that the clamped label cannot reach —
  /// the content sits 5pt from the top and 17pt from the bottom no matter what
  /// insets the items carry.
  ///
  /// On iOS 26 this reservation is load-bearing: it is what keeps the real
  /// glass bar clear of the indicator, so it is left completely alone.
  public override var safeAreaInsets: UIEdgeInsets {
    guard #unavailable(iOS 26.0) else { return super.safeAreaInsets }
    return .zero
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    guard collapseAnimator?.isRunning != true else { return }
    let frame = resolvedTabFrame(compact: isCompact)
    tabBar.frame = frame
    updateLegacyLayout(compact: isCompact)
  }

  func setItems(_ definitions: [ExpoNativeCompactTabItem]) {
    let changed = definitions.count != itemDefinitions.count ||
      zip(definitions, itemDefinitions).contains { next, current in
        next.key != current.key || next.label != current.label ||
          next.imageUri != current.imageUri ||
          next.animationFrameUris != current.animationFrameUris ||
          next.accessibilityLabel != current.accessibilityLabel
      }

    guard changed else { return }
    stopIconAnimation(resetToRestingFrame: false)
    itemDefinitions = definitions
    animationFrames = Array(repeating: [], count: definitions.count)
    imageLoadGeneration = UUID()
    let generation = imageLoadGeneration

    tabBar.items = definitions.map { definition in
      let item = UITabBarItem(
        title: isCompact ? nil : definition.label,
        image: nil,
        selectedImage: nil
      )
      applyItemLayout(item, compact: isCompact)
      item.accessibilityLabel = definition.accessibilityLabel ?? definition.label
      return item
    }

    for (index, definition) in definitions.enumerated() {
      let uris = definition.animationFrameUris.isEmpty
        ? [definition.imageUri]
        : definition.animationFrameUris
      loadImages(uris, itemIndex: index, generation: generation)
    }

    applySelectedIndex()
    setNeedsLayout()
  }

  func setSelectedIndex(_ index: Int) {
    guard selectedIndex != index else { return }
    selectedIndex = index
    applySelectedIndex()
    animateLegacySelection(to: index)
    playIconAnimation(at: index)
  }

  func setCompact(_ compact: Bool) {
    guard isCompact != compact else { return }
    isCompact = compact

    collapseAnimator?.stopAnimation(true)

    let updateTitles = {
      for (index, item) in (self.tabBar.items ?? []).enumerated() {
        item.title = compact ? nil : self.itemDefinitions[index].label
        self.applyItemLayout(item, compact: compact)
      }
    }

    UIView.transition(
      with: tabBar,
      duration: 0.2,
      options: [.transitionCrossDissolve, .beginFromCurrentState, .allowAnimatedContent],
      animations: updateTitles
    )

    // The collapse animator also drives `legacySelectionView.frame`, so a
    // selection spring still in flight would fight it — tap a tab as a scroll
    // triggers compact and whichever animator lands second leaves the capsule
    // on a stale target.
    legacySelectionAnimator?.stopAnimation(true)
    legacySelectionAnimator = nil

    let animator = UIViewPropertyAnimator(duration: 0.38, dampingRatio: 1) {
      let frame = self.resolvedTabFrame(compact: compact)
      self.tabBar.frame = frame
      self.updateLegacyLayout(compact: compact)
      self.tabBar.layoutIfNeeded()
    }
    collapseAnimator = animator
    animator.addCompletion { [weak self] _ in
      self?.collapseAnimator = nil
    }
    animator.startAnimation()
  }

  public func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    guard let index = tabBar.items?.firstIndex(of: item) else { return }
    let isReselection = index == selectedIndex
    selectedIndex = index
    animateLegacySelection(to: index)
    playIconAnimation(at: index)

    if isReselection {
      scrollSelectedTabToTop(animated: true)
    }

    onTabSelected(["index": index])

    if !isReselection {
      resetDestinationWhenSelected(index)
    }
  }

  private func loadImages(_ uris: [String], itemIndex: Int, generation: UUID) {
    let group = DispatchGroup()
    var loaded = Array<UIImage?>(repeating: nil, count: uris.count)

    for (frameIndex, uri) in uris.enumerated() {
      group.enter()
      loadImage(uri) { image in
        loaded[frameIndex] = image?.withRenderingMode(.alwaysTemplate)
        group.leave()
      }
    }

    group.notify(queue: .main) { [weak self] in
      guard let self, self.imageLoadGeneration == generation,
        self.animationFrames.indices.contains(itemIndex)
      else { return }

      let frames = loaded.compactMap { $0 }
      guard let restingImage = frames.first else { return }
      self.animationFrames[itemIndex] = frames
      self.setImage(restingImage, forItemAt: itemIndex)
    }
  }

  private func loadImage(_ uri: String, completion: @escaping (UIImage?) -> Void) {
    let cacheKey = uri as NSString
    if let cached = Self.imageCache.object(forKey: cacheKey) {
      completion(cached)
      return
    }

    guard let url = URL(string: uri) else {
      completion(nil)
      return
    }

    if url.isFileURL {
      let image = UIImage(contentsOfFile: url.path)
      if let image { Self.imageCache.setObject(image, forKey: cacheKey) }
      completion(image)
      return
    }

    URLSession.shared.dataTask(with: url) { data, _, _ in
      let image = data.flatMap {
        UIImage(data: $0, scale: UIScreen.main.scale)
      }
      if let image { Self.imageCache.setObject(image, forKey: cacheKey) }
      DispatchQueue.main.async { completion(image) }
    }.resume()
  }

  private func playIconAnimation(at index: Int) {
    guard !UIAccessibility.isReduceMotionEnabled,
      animationFrames.indices.contains(index),
      animationFrames[index].count > 1
    else { return }

    stopIconAnimation(resetToRestingFrame: true)
    animatingIndex = index
    animationFrameIndex = 0
    setImage(animationFrames[index][0], forItemAt: index)

    let timer = Timer(timeInterval: animationFrameDuration, repeats: true) { [weak self] _ in
      guard let self, let activeIndex = self.animatingIndex else { return }
      if UIAccessibility.isReduceMotionEnabled {
        self.stopIconAnimation(resetToRestingFrame: true)
        return
      }

      self.animationFrameIndex += 1
      guard self.animationFrameIndex < self.animationFrames[activeIndex].count else {
        self.stopIconAnimation(resetToRestingFrame: true)
        return
      }
      self.setImage(
        self.animationFrames[activeIndex][self.animationFrameIndex],
        forItemAt: activeIndex
      )
    }
    iconAnimationTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func stopIconAnimation(resetToRestingFrame: Bool) {
    iconAnimationTimer?.invalidate()
    iconAnimationTimer = nil

    if resetToRestingFrame, let index = animatingIndex,
      animationFrames.indices.contains(index),
      let restingImage = animationFrames[index].first
    {
      setImage(restingImage, forItemAt: index)
    }
    animatingIndex = nil
    animationFrameIndex = 0
  }

  private func setImage(_ image: UIImage, forItemAt index: Int) {
    guard let items = tabBar.items, items.indices.contains(index) else { return }
    items[index].image = image
    items[index].selectedImage = image
  }

  private func scrollSelectedTabToTop(animated: Bool) {
    guard
      let rootController = nearestViewController() ?? window?.rootViewController,
      let tabsController = findNativeTabsController(in: rootController),
      let selectedController = tabsController.selectedViewController,
      let scrollView = firstScrollViewInDescendantChain(from: selectedController.view)
    else { return }

    let topOffset = CGPoint(x: 0, y: -scrollView.adjustedContentInset.top)
    if scrollView.contentOffset != topOffset {
      scrollView.setContentOffset(topOffset, animated: animated)
    }

    // On iOS 18 the automatic inset can settle after a destination controller
    // becomes selected, or while an animated reselect is in flight. The early
    // value is commonly zero, which leaves the first section under the fixed
    // header once the real safe-area inset arrives. Preserve the immediate
    // reset/native animation, then reconcile against the settled negative
    // inset. Destination changes get three quick layout passes; an animated
    // reselect gets one pass after UIKit's animation finishes.
    let selectedIndexAtStart = selectedIndex
    reconcileScrollViewToTop(
      scrollView,
      selectedIndex: selectedIndexAtStart,
      after: animated ? 0.45 : 0.10,
      remainingPasses: animated ? 1 : 3
    )
  }

  private func reconcileScrollViewToTop(
    _ scrollView: UIScrollView,
    selectedIndex: Int,
    after delay: TimeInterval,
    remainingPasses: Int
  ) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak scrollView] in
      guard let self, let scrollView,
        self.selectedIndex == selectedIndex,
        !scrollView.isTracking,
        !scrollView.isDragging,
        !scrollView.isDecelerating
      else { return }

      let settledTop = CGPoint(x: 0, y: -scrollView.adjustedContentInset.top)
      if abs(scrollView.contentOffset.y - settledTop.y) > 0.5 {
        scrollView.setContentOffset(settledTop, animated: false)
      }

      guard remainingPasses > 1 else { return }
      self.reconcileScrollViewToTop(
        scrollView,
        selectedIndex: selectedIndex,
        after: 0.10,
        remainingPasses: remainingPasses - 1
      )
    }
  }

  /// The standalone bar selects immediately, while Expo Router changes the
  /// hidden native `UITabBarController` asynchronously. Poll the controller's
  /// own selected index before touching its ScrollView; a one-run-loop delay
  /// can still resolve the outgoing tab and reset the screen being left.
  private func resetDestinationWhenSelected(_ index: Int, attempt: Int = 0) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
      guard let self, self.selectedIndex == index else { return }

      let rootController = self.nearestViewController() ?? self.window?.rootViewController
      if let rootController,
        let tabsController = self.findNativeTabsController(in: rootController),
        tabsController.selectedIndex == index
      {
        self.scrollSelectedTabToTop(animated: false)
        return
      }

      guard attempt < 59 else { return }
      self.resetDestinationWhenSelected(index, attempt: attempt + 1)
    }
  }

  private func nearestViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let current = responder {
      if let controller = current as? UIViewController { return controller }
      responder = current.next
    }
    return nil
  }

  private func findNativeTabsController(in controller: UIViewController) -> UITabBarController? {
    if let presented = controller.presentedViewController,
      let tabsController = findNativeTabsController(in: presented)
    { return tabsController }

    if let tabsController = controller as? UITabBarController,
      tabsController.tabBar !== tabBar,
      tabsController.viewIfLoaded?.window != nil
    { return tabsController }

    for child in controller.children.reversed() {
      if let tabsController = findNativeTabsController(in: child) { return tabsController }
    }
    return nil
  }

  private func firstScrollViewInDescendantChain(from root: UIView?) -> UIScrollView? {
    var current = root
    while let view = current {
      if let scrollView = view as? UIScrollView { return scrollView }
      current = view.subviews.first
    }
    return nil
  }

  private func applySelectedIndex() {
    guard let items = tabBar.items, items.indices.contains(selectedIndex) else { return }
    tabBar.selectedItem = items[selectedIndex]
  }

  private func applyItemLayout(_ item: UITabBarItem, compact: Bool) {
    // No legacy special case. The items belong to the same UITabBar on both
    // paths, at the same frame, so the offsets Apple already positions
    // correctly on iOS 26 are correct here too. Every attempt to tune these
    // separately fought a bar/surface mismatch that no inset could fix.
    if #unavailable(iOS 26.0) {
      // The bar is now the pill, so these are small corrections inside a
      // correctly-sized box rather than an attempt to bridge two boxes.
      // Zero: with the pill sized to the item area there is nothing to
      // correct for, and any upward push lifts the glyph out through the top.
      // Expanded lifts the glyph to make room for the label beneath it;
      // compact has no label, so the icon simply centres.
      // Measured on device: UIKit's default stacked gap is 9pt (icon bottom
      // 30.33 → label top 39.33 in a 58pt bar). Shrinking it means moving the
      // two by DIFFERENT amounts — every earlier pass moved both equally,
      // which slid the pair and left the gap untouched. Splitting the 5pt
      // correction symmetrically keeps the group centroid where it is.
      // Both numbers are measured, not guessed. On a 58pt pill the visible
      // glyph ran 12.33→29.00 and the label 39.00→46.00, so the visual gap was
      // 10pt; shrinking it to ~6 means splitting 4pt between the two so the
      // group's centroid does not move. Compact is a separate visual case:
      // after the pill itself was lifted clear of the home indicator, the
      // glyphs visibly remained about 8pt above its centre. The negative
      // offset lowers only the label-free compact glyph row.
      //
      // Note the glyph is ~16.7pt inside a 24pt image box — the PNGs carry
      // transparent padding, so the visual gap is always wider than the box
      // maths suggests. Measure the glyph, not the box.
      let legacyImageOffset: CGFloat = compact ? -5.2 : 0.5
      item.imageInsets = UIEdgeInsets(
        top: -legacyImageOffset,
        left: 0,
        bottom: legacyImageOffset,
        right: 0
      )
      // NOTE: the label is NOT set here. Assigning a `UITabBarAppearance`
      // makes UIKit ignore `UITabBarItem.titlePositionAdjustment` entirely,
      // so setting it here renders nothing and reads as a live knob that
      // silently does nothing. It lives in `configureLegacyAppearance()`.
      return
    }

    let imageOffset: CGFloat = compact ? -8 : 26
    let titleOffset: CGFloat = compact ? 0 : 2
    item.imageInsets = UIEdgeInsets(
      top: -imageOffset,
      left: 0,
      bottom: imageOffset,
      right: 0
    )
    item.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: titleOffset)
  }

  /// `CALayer.borderColor` is a `CGColor` and cannot hold a dynamic provider,
  /// so it has to be re-resolved by hand whenever the appearance changes.
  /// `backgroundColor` on the views themselves needs none of this — `UIView`
  /// resolves dynamic `UIColor`s on its own.
  private static let legacyBorderColor = UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor.white.withAlphaComponent(0.10)
      : UIColor.black.withAlphaComponent(0.10)
  }

  public override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    guard #unavailable(iOS 26.0) else { return }
    guard traitCollection.userInterfaceStyle != previous?.userInterfaceStyle else { return }
    legacyBackgroundView.layer.borderColor = Self.legacyBorderColor
      .resolvedColor(with: traitCollection)
      .cgColor
  }

  private func configureLegacyAppearance() {
    let appearance = UITabBarAppearance()
    appearance.configureWithTransparentBackground()
    appearance.backgroundEffect = nil
    appearance.backgroundColor = .clear
    appearance.shadowColor = .clear

    // Title position must be set HERE, not on the UITabBarItem.
    //
    // Assigning a `UITabBarAppearance` supersedes `UITabBarItem`'s own
    // `titlePositionAdjustment` — the item property is silently ignored. That
    // is why the label refused to move for any value: it was never being read.
    let titleOffset = UIOffset(horizontal: 0, vertical: -9.5)
    appearance.stackedLayoutAppearance.normal.titlePositionAdjustment = titleOffset
    appearance.stackedLayoutAppearance.selected.titlePositionAdjustment = titleOffset
    appearance.stackedLayoutAppearance.disabled.titlePositionAdjustment = titleOffset
    appearance.inlineLayoutAppearance.normal.titlePositionAdjustment = titleOffset
    appearance.inlineLayoutAppearance.selected.titlePositionAdjustment = titleOffset
    appearance.compactInlineLayoutAppearance.normal.titlePositionAdjustment = titleOffset
    appearance.compactInlineLayoutAppearance.selected.titlePositionAdjustment = titleOffset

    tabBar.standardAppearance = appearance
    tabBar.scrollEdgeAppearance = appearance
    tabBar.clipsToBounds = false

    legacyBackgroundView.isUserInteractionEnabled = false
    legacyBackgroundView.layer.cornerCurve = .continuous
    legacyBackgroundView.layer.masksToBounds = true
    legacyBackgroundView.layer.borderWidth = 1
    legacyBackgroundView.layer.borderColor = Self.legacyBorderColor
      .resolvedColor(with: traitCollection)
      .cgColor
    legacyBackgroundView.backgroundColor = UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(white: 0.07, alpha: 0.94)
        : UIColor(white: 0.98, alpha: 0.94)
    }

    legacySelectionView.isUserInteractionEnabled = false
    legacySelectionView.layer.cornerCurve = .continuous
    legacySelectionView.backgroundColor = UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor.white.withAlphaComponent(0.14)
        : UIColor.black.withAlphaComponent(0.08)
    }
  }

  private func updateLegacyLayout(compact: Bool) {
    guard #unavailable(iOS 26.0) else { return }
    let surfaceFrame = legacySurfaceFrame(compact: compact)
    legacyBackgroundView.frame = surfaceFrame
    legacyBackgroundView.layer.cornerRadius = surfaceFrame.height / 2

    let selectionFrame = legacySelectionFrame(index: selectedIndex, compact: compact)
    legacySelectionView.isHidden = selectionFrame.isEmpty
    legacySelectionView.frame = selectionFrame
    legacySelectionView.layer.cornerRadius = selectionFrame.height / 2
  }

  private func animateLegacySelection(to index: Int) {
    guard #unavailable(iOS 26.0), !(tabBar.items ?? []).isEmpty else { return }
    legacySelectionAnimator?.stopAnimation(true)
    let animator = UIViewPropertyAnimator(duration: 0.42, dampingRatio: 0.82) {
      let frame = self.legacySelectionFrame(index: index, compact: self.isCompact)
      self.legacySelectionView.frame = frame
      self.legacySelectionView.layer.cornerRadius = frame.height / 2
    }
    legacySelectionAnimator = animator
    animator.addCompletion { [weak self] _ in
      self?.legacySelectionAnimator = nil
    }
    animator.startAnimation()
  }

  /// The legacy pill is the bar's own frame, not a box of its own.
  ///
  /// It used to be 58/44pt at a separately-computed bottom offset while the
  /// `UITabBar` stayed 78/70pt at `targetFrame`'s y. The items are laid out
  /// inside the BAR, so the labels and icons were positioned against one box
  /// and drawn over another — which reads as "the text is in the wrong place"
  /// and cannot be corrected with item insets. Matching the frame exactly
  /// makes the pre-26 surface land where the glass lands on 26.
  private func legacySurfaceFrame(compact: Bool) -> CGRect {
    resolvedTabFrame(compact: compact)
  }

  private func legacySelectionFrame(index: Int, compact: Bool) -> CGRect {
    guard let items = tabBar.items, !items.isEmpty else { return .zero }
    let surfaceFrame = legacySurfaceFrame(compact: compact)
    let itemWidth = surfaceFrame.width / CGFloat(items.count)
    let clampedIndex = min(max(index, 0), items.count - 1)
    let verticalInset: CGFloat = 4
    // In the PILL's coordinates, so it inherits the pill's position for free.
    return CGRect(
      x: itemWidth * CGFloat(clampedIndex) + 4,
      y: verticalInset,
      width: max(itemWidth - 8, 0),
      height: max(surfaceFrame.height - verticalInset * 2, 0)
    )
  }


  private func targetFrame(compact: Bool) -> CGRect {
    let expandedWidth = max(bounds.width - expandedHorizontalInset * 2, 0)
    let width = compact ? min(compactWidth, expandedWidth) : expandedWidth
    let height = compact ? compactHeight : expandedHeight
    return CGRect(
      x: (bounds.width - width) / 2,
      y: bounds.height - height,
      width: width,
      height: height
    )
  }

  private func resolvedTabFrame(compact: Bool) -> CGRect {
    let frame = targetFrame(compact: compact)
    guard #unavailable(iOS 26.0) else { return frame }

    // iOS 26's UITabBar draws its visible glass inside the view's raw frame.
    // Reproduce that optical inset for the solid legacy surface and its items.
    let opticalInset: CGFloat = compact ? 21 : 18
    let inset = frame.insetBy(dx: min(opticalInset, frame.width / 2), dy: 0)

    // And give legacy its OWN height, rather than inheriting iOS 26's 78/70.
    //
    // A UITabBar lays its items into roughly the top 49pt of its frame and
    // clamps the label to the bottom of that area. Inheriting a 78pt frame
    // therefore parks the whole stack near the top with dead space beneath it,
    // and the label physically cannot descend to meet a pill drawn lower —
    // which is what made the text look wrong at every item inset we tried.
    // Sizing the frame to the pill puts the item area and the surface in the
    // same box, so UIKit's own centring does the work.
    // Sized to the item area, not chosen for looks. UIKit anchors the ~49pt
    // item area to the TOP of the bar, so any surplus height becomes dead
    // space along the bottom that the clamped label can never reach into.
    let legacyHeight: CGFloat = compact ? 44 : 58
    // The compact pill has no label stack, so leaving its lower edge on the
    // expanded baseline makes the smaller surface crowd the home indicator.
    // Lift only the legacy compact surface; iOS 26 owns its own optical
    // placement, and the legacy expanded placement is already signed off.
    let compactLift: CGFloat = compact ? 6 : 0
    let bottomOffset = max((window?.safeAreaInsets.bottom ?? 0) - 16, 12) + compactLift
    return CGRect(
      x: inset.minX,
      y: bounds.height - bottomOffset - legacyHeight,
      width: inset.width,
      height: legacyHeight
    )
  }
}

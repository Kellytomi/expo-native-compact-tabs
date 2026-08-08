import ExpoModulesCore
import UIKit

private final class HorizontalPanGestureDelegate: NSObject, UIGestureRecognizerDelegate {
  var shouldBegin: ((UIPanGestureRecognizer) -> Bool)?

  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard let panGesture = gestureRecognizer as? UIPanGestureRecognizer else { return false }
    return shouldBegin?(panGesture) ?? false
  }
}

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
  private var legacySelectionPanGesture: UIPanGestureRecognizer?
  private let legacySelectionPanDelegate = HorizontalPanGestureDelegate()
  private let legacySelectionFeedback = UISelectionFeedbackGenerator()
  private var legacyDragGrabOffsetX: CGFloat = 0
  private var legacyPreviewIndex = 0
  private var isLegacyDragging = false
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

  var selectionDragEnabled = true {
    didSet {
      guard #unavailable(iOS 26.0) else { return }
      if !selectionDragEnabled, isLegacyDragging {
        cancelLegacySelectionDrag()
      }
      legacySelectionPanGesture?.isEnabled = selectionDragEnabled
    }
  }

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
      configureLegacySelectionGesture()
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
    if !isLegacyDragging {
      updateLegacyLayout(compact: isCompact)
    }
  }

  func setItems(_ definitions: [ExpoNativeCompactTabItem]) {
    let changed = definitions.count != itemDefinitions.count ||
      zip(definitions, itemDefinitions).contains { next, current in
        next.key != current.key || next.label != current.label ||
          next.imageUri != current.imageUri ||
          next.imageScale != current.imageScale ||
          next.animationFrameUris != current.animationFrameUris ||
          next.animationFrameScales != current.animationFrameScales ||
          next.accessibilityLabel != current.accessibilityLabel
      }

    guard changed else { return }
    if isLegacyDragging {
      cancelLegacySelectionDrag()
    }
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
      let scales = definition.animationFrameUris.isEmpty
        ? [definition.imageScale]
        : definition.animationFrameScales
      loadImages(uris, scales: scales, itemIndex: index, generation: generation)
    }

    applySelectedIndex()
    setNeedsLayout()
  }

  func setSelectedIndex(_ index: Int) {
    guard selectedIndex != index else { return }
    if isLegacyDragging {
      cancelLegacySelectionDrag()
    }
    selectedIndex = index
    applySelectedIndex()
    animateLegacySelection(to: index)
    playIconAnimation(at: index)
  }

  func setCompact(_ compact: Bool) {
    guard isCompact != compact else { return }
    if isLegacyDragging {
      cancelLegacySelectionDrag()
    }
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

  private func configureLegacySelectionGesture() {
    guard #unavailable(iOS 26.0) else { return }
    let panGesture = UIPanGestureRecognizer(
      target: self,
      action: #selector(handleLegacySelectionPan(_:))
    )
    legacySelectionPanDelegate.shouldBegin = { [weak self] panGesture in
      self?.shouldBeginLegacySelectionPan(panGesture) ?? false
    }
    panGesture.delegate = legacySelectionPanDelegate
    panGesture.cancelsTouchesInView = true
    panGesture.maximumNumberOfTouches = 1
    panGesture.isEnabled = selectionDragEnabled
    tabBar.addGestureRecognizer(panGesture)
    legacySelectionPanGesture = panGesture
  }

  private func shouldBeginLegacySelectionPan(_ panGesture: UIPanGestureRecognizer) -> Bool {
    guard #unavailable(iOS 26.0), selectionDragEnabled,
      !(tabBar.items ?? []).isEmpty
    else { return false }

    let velocity = panGesture.velocity(in: tabBar)
    if abs(velocity.x) < 0.01, abs(velocity.y) < 0.01 {
      return true
    }
    return abs(velocity.x) > abs(velocity.y)
  }

  @objc private func handleLegacySelectionPan(_ panGesture: UIPanGestureRecognizer) {
    guard #unavailable(iOS 26.0), selectionDragEnabled else { return }
    let location = panGesture.location(in: legacyBackgroundView)
    let velocity = panGesture.velocity(in: legacyBackgroundView)

    switch panGesture.state {
    case .began:
      beginLegacySelectionDrag(at: location)
      updateLegacySelectionDrag(at: location, velocityX: velocity.x)
    case .changed:
      updateLegacySelectionDrag(at: location, velocityX: velocity.x)
    case .ended:
      finishLegacySelectionDrag(velocityX: velocity.x)
    case .cancelled, .failed:
      cancelLegacySelectionDrag()
    default:
      break
    }
  }

  private func beginLegacySelectionDrag(at location: CGPoint) {
    guard #unavailable(iOS 26.0), !(tabBar.items ?? []).isEmpty else { return }

    let visibleFrame = legacySelectionView.layer.presentation()?.frame
      ?? legacySelectionView.frame
    legacySelectionAnimator?.stopAnimation(true)
    legacySelectionAnimator = nil
    legacySelectionView.layer.removeAllAnimations()
    legacySelectionView.frame = visibleFrame

    let forgivingHitFrame = visibleFrame.insetBy(dx: -12, dy: -12)
    legacyDragGrabOffsetX = forgivingHitFrame.contains(location)
      ? location.x - visibleFrame.midX
      : 0
    legacyPreviewIndex = selectedIndex
    isLegacyDragging = true
    legacySelectionFeedback.prepare()
  }

  private func updateLegacySelectionDrag(at location: CGPoint, velocityX: CGFloat) {
    guard #unavailable(iOS 26.0), isLegacyDragging,
      let items = tabBar.items, !items.isEmpty,
      legacyBackgroundView.bounds.width > 0
    else { return }

    let itemWidth = legacyBackgroundView.bounds.width / CGFloat(items.count)
    let baseWidth = max(itemWidth - 8, 0)
    let horizontalInset: CGFloat = 4
    let stretch = min(abs(velocityX) * 0.006, itemWidth * 0.14)
    let directionalShift = min(abs(velocityX) * 0.003, itemWidth * 0.08)
    let direction: CGFloat = velocityX == 0 ? 0 : (velocityX > 0 ? 1 : -1)
    let halfWidth = baseWidth / 2 + stretch
    let minimumCenter = horizontalInset + halfWidth
    let maximumCenter = legacyBackgroundView.bounds.width - horizontalInset - halfWidth
    let proposedCenter = location.x - legacyDragGrabOffsetX + direction * directionalShift
    let centerX = min(max(proposedCenter, minimumCenter), maximumCenter)
    let verticalInset: CGFloat = 4
    let frame = CGRect(
      x: centerX - halfWidth,
      y: verticalInset,
      width: halfWidth * 2,
      height: max(legacyBackgroundView.bounds.height - verticalInset * 2, 0)
    )

    UIView.performWithoutAnimation {
      self.legacySelectionView.frame = frame
      self.legacySelectionView.layer.cornerRadius = frame.height / 2
    }

    let previewIndex = legacyIndex(at: location.x)
    if previewIndex != legacyPreviewIndex {
      legacyPreviewIndex = previewIndex
      tabBar.selectedItem = items[previewIndex]
      legacySelectionFeedback.selectionChanged()
      legacySelectionFeedback.prepare()
    }
  }

  private func finishLegacySelectionDrag(velocityX: CGFloat) {
    guard #unavailable(iOS 26.0), isLegacyDragging,
      let items = tabBar.items, !items.isEmpty
    else { return }

    let projectedCenter = legacySelectionView.frame.midX + velocityX * 0.08
    let destinationIndex = legacyIndex(at: projectedCenter)
    let previousIndex = selectedIndex
    selectedIndex = destinationIndex
    legacyPreviewIndex = destinationIndex
    isLegacyDragging = false
    tabBar.selectedItem = items[destinationIndex]
    animateLegacySelection(to: destinationIndex, initialVelocity: velocityX)

    guard destinationIndex != previousIndex else { return }
    playIconAnimation(at: destinationIndex)
    onTabSelected(["index": destinationIndex])
    resetDestinationWhenSelected(destinationIndex)
  }

  private func cancelLegacySelectionDrag() {
    guard #unavailable(iOS 26.0), isLegacyDragging else { return }
    isLegacyDragging = false
    legacyPreviewIndex = selectedIndex
    applySelectedIndex()
    animateLegacySelection(to: selectedIndex)
  }

  private func legacyIndex(at locationX: CGFloat) -> Int {
    guard let items = tabBar.items, !items.isEmpty,
      legacyBackgroundView.bounds.width > 0
    else { return 0 }

    let fraction = min(max(locationX / legacyBackgroundView.bounds.width, 0), 0.999_999)
    return min(max(Int(fraction * CGFloat(items.count)), 0), items.count - 1)
  }

  private func loadImages(
    _ uris: [String],
    scales: [Double],
    itemIndex: Int,
    generation: UUID
  ) {
    let group = DispatchGroup()
    var loaded = Array<UIImage?>(repeating: nil, count: uris.count)

    for (frameIndex, uri) in uris.enumerated() {
      group.enter()
      let scale = scales.indices.contains(frameIndex) ? scales[frameIndex] : 0
      loadImage(uri, scale: scale) { image in
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

  private func loadImage(
    _ uri: String,
    scale: Double,
    completion: @escaping (UIImage?) -> Void
  ) {
    guard let url = URL(string: uri) else {
      completion(nil)
      return
    }

    let resolvedScale = scale > 0
      ? CGFloat(scale)
      : (url.isFileURL ? 1 : UIScreen.main.scale)
    let cacheKey = "\(uri)#scale=\(resolvedScale)" as NSString
    if let cached = Self.imageCache.object(forKey: cacheKey) {
      completion(cached)
      return
    }

    if url.isFileURL {
      let image = (try? Data(contentsOf: url)).flatMap {
        UIImage(data: $0, scale: resolvedScale)
      }
      if let image { Self.imageCache.setObject(image, forKey: cacheKey) }
      completion(image)
      return
    }

    URLSession.shared.dataTask(with: url) { data, _, _ in
      let image = data.flatMap {
        UIImage(data: $0, scale: resolvedScale)
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

  private func animateLegacySelection(to index: Int, initialVelocity: CGFloat = 0) {
    guard #unavailable(iOS 26.0), !(tabBar.items ?? []).isEmpty else { return }

    let targetFrame = legacySelectionFrame(index: index, compact: isCompact)
    if UIAccessibility.isReduceMotionEnabled {
      legacySelectionAnimator?.stopAnimation(true)
      legacySelectionAnimator = nil
      legacySelectionView.layer.removeAllAnimations()
      UIView.performWithoutAnimation {
        self.legacySelectionView.frame = targetFrame
        self.legacySelectionView.layer.cornerRadius = targetFrame.height / 2
      }
      return
    }

    let visibleFrame = legacySelectionView.layer.presentation()?.frame
      ?? legacySelectionView.frame
    legacySelectionAnimator?.stopAnimation(true)
    legacySelectionView.layer.removeAllAnimations()
    legacySelectionView.frame = visibleFrame

    let animator: UIViewPropertyAnimator
    let distance = targetFrame.midX - visibleFrame.midX
    if abs(initialVelocity) > 0.5, abs(distance) > 0.5 {
      let relativeVelocity = min(max(initialVelocity / distance, -12), 12)
      let spring = UISpringTimingParameters(
        dampingRatio: 0.82,
        initialVelocity: CGVector(dx: relativeVelocity, dy: 0)
      )
      animator = UIViewPropertyAnimator(duration: 0.42, timingParameters: spring)
    } else {
      animator = UIViewPropertyAnimator(duration: 0.42, dampingRatio: 0.82)
    }
    animator.addAnimations {
      self.legacySelectionView.frame = targetFrame
      self.legacySelectionView.layer.cornerRadius = targetFrame.height / 2
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

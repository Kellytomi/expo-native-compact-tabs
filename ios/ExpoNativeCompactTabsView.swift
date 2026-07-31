import ExpoModulesCore
import UIKit

public final class ExpoNativeCompactTabsView: ExpoView, UITabBarDelegate {
  private static let imageCache = NSCache<NSString, UIImage>()

  let onTabSelected = EventDispatcher()

  private let tabBar = UITabBar(frame: .zero)
  private var itemDefinitions: [ExpoNativeCompactTabItem] = []
  private var animationFrames: [[UIImage]] = []
  private var selectedIndex = 0
  private var isCompact = false
  private var collapseAnimator: UIViewPropertyAnimator?
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
    tabBar.clipsToBounds = false
    addSubview(tabBar)
  }

  deinit {
    iconAnimationTimer?.invalidate()
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    guard collapseAnimator?.isRunning != true else { return }
    tabBar.frame = targetFrame(compact: isCompact)
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

    let animator = UIViewPropertyAnimator(duration: 0.38, dampingRatio: 1) {
      self.tabBar.frame = self.targetFrame(compact: compact)
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
    playIconAnimation(at: index)

    if isReselection {
      scrollSelectedTabToTop()
    }

    onTabSelected(["index": index])
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

  private func scrollSelectedTabToTop() {
    guard
      let rootController = nearestViewController() ?? window?.rootViewController,
      let tabsController = findNativeTabsController(in: rootController),
      let selectedController = tabsController.selectedViewController,
      let scrollView = firstScrollViewInDescendantChain(from: selectedController.view)
    else { return }

    let topOffset = CGPoint(x: 0, y: -scrollView.adjustedContentInset.top)
    guard scrollView.contentOffset != topOffset else { return }
    scrollView.setContentOffset(topOffset, animated: true)
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
}

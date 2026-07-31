import ExpoModulesCore

struct ExpoNativeCompactTabItem: Record {
  @Field var key: String = ""
  @Field var label: String = ""
  @Field var imageUri: String = ""
  @Field var animationFrameUris: [String] = []
  @Field var accessibilityLabel: String?
}

public final class ExpoNativeCompactTabsModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoNativeCompactTabs")

    View(ExpoNativeCompactTabsView.self) {
      Events("onTabSelected")

      Prop("items") { (view: ExpoNativeCompactTabsView, items: [ExpoNativeCompactTabItem]) in
        view.setItems(items)
      }

      Prop("selectedIndex") { (view: ExpoNativeCompactTabsView, index: Int) in
        view.setSelectedIndex(index)
      }

      Prop("compact") { (view: ExpoNativeCompactTabsView, compact: Bool) in
        view.setCompact(compact)
      }

      Prop("tintColor") { (view: ExpoNativeCompactTabsView, color: UIColor?) in
        view.tabTintColor = color
      }

      Prop("inactiveTintColor") { (view: ExpoNativeCompactTabsView, color: UIColor?) in
        view.inactiveTabTintColor = color
      }

      Prop("expandedHorizontalInset") { (view: ExpoNativeCompactTabsView, inset: CGFloat?) in
        view.expandedHorizontalInset = inset ?? 12
      }

      Prop("compactWidth") { (view: ExpoNativeCompactTabsView, width: CGFloat?) in
        view.compactWidth = width ?? 352
      }

      Prop("expandedHeight") { (view: ExpoNativeCompactTabsView, height: CGFloat?) in
        view.expandedHeight = height ?? 78
      }

      Prop("compactHeight") { (view: ExpoNativeCompactTabsView, height: CGFloat?) in
        view.compactHeight = height ?? 70
      }

      Prop("animationFrameDuration") { (view: ExpoNativeCompactTabsView, duration: Double?) in
        view.animationFrameDuration = duration ?? 0.034
      }
    }
  }
}

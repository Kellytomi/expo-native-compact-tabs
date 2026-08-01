package expo.modules.nativecompacttabs

import android.graphics.Color
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.records.Field
import expo.modules.kotlin.records.Record
import expo.modules.kotlin.types.OptimizedRecord

@OptimizedRecord
class ExpoNativeCompactTabItem : Record {
  @Field
  var key: String = ""

  @Field
  var label: String = ""

  @Field
  var imageUri: String = ""

  @Field
  var animationFrameUris: List<String> = emptyList()

  @Field
  var accessibilityLabel: String? = null
}

@Suppress("unused")
class ExpoNativeCompactTabsModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("ExpoNativeCompactTabs")

    View(ExpoNativeCompactTabsView::class) {
      Events("onTabSelected")

      Prop("items") { view: ExpoNativeCompactTabsView, items: List<ExpoNativeCompactTabItem> ->
        view.setItems(items)
      }

      Prop("selectedIndex") { view: ExpoNativeCompactTabsView, index: Int ->
        view.setSelectedIndex(index)
      }

      Prop("compact") { view: ExpoNativeCompactTabsView, compact: Boolean ->
        view.setCompact(compact)
      }

      Prop("tintColor") { view: ExpoNativeCompactTabsView, color: Color? ->
        view.setTintColor(color)
      }

      Prop("inactiveTintColor") { view: ExpoNativeCompactTabsView, color: Color? ->
        view.setInactiveTintColor(color)
      }

      Prop("expandedHorizontalInset") { view: ExpoNativeCompactTabsView, inset: Double? ->
        view.expandedHorizontalInset = inset?.toFloat() ?: 12f
      }

      Prop("compactWidth") { view: ExpoNativeCompactTabsView, width: Double? ->
        view.compactWidth = width?.toFloat() ?: 352f
      }

      Prop("expandedHeight") { view: ExpoNativeCompactTabsView, height: Double? ->
        view.expandedHeight = height?.toFloat() ?: 78f
      }

      Prop("compactHeight") { view: ExpoNativeCompactTabsView, height: Double? ->
        view.compactHeight = height?.toFloat() ?: 70f
      }

      Prop("animationFrameDuration") { view: ExpoNativeCompactTabsView, duration: Double? ->
        view.animationFrameDuration = duration ?: 0.034
      }

      Prop("selectionDragEnabled") { view: ExpoNativeCompactTabsView, enabled: Boolean? ->
        view.selectionDragEnabled = enabled ?: true
      }
    }
  }
}

package expo.modules.nativecompacttabs

import android.animation.ValueAnimator
import android.content.Context
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.LruCache
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.dynamicanimation.animation.FloatPropertyCompat
import androidx.dynamicanimation.animation.SpringAnimation
import androidx.dynamicanimation.animation.SpringForce
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.types.ColorCompat
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

class ExpoNativeCompactTabsView(
  context: Context,
  appContext: AppContext
) : ExpoView(context, appContext) {
  val onTabSelected by EventDispatcher()

  private val density = resources.displayMetrics.density
  private val mainHandler = Handler(Looper.getMainLooper())
  private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop.toFloat()
  private val surfaceView = FrameLayout(context)
  private val selectionView = View(context)
  private val itemsRow = LinearLayout(context)
  private val itemViews = mutableListOf<TabItemView>()
  private var itemDefinitions: List<ExpoNativeCompactTabItem> = emptyList()
  private var animationFrames: MutableList<List<Bitmap>> = mutableListOf()
  private var imageLoadGeneration = 0
  private var selectedIndex = 0
  private var previewIndex = 0
  private var isCompact = false

  private var selectedTint = resolveThemeColor(android.R.attr.colorAccent, Color.rgb(255, 90, 54))
  private var inactiveTint = Color.rgb(142, 142, 147)

  private var surfaceLeft = Float.NaN
  private var surfaceTop = Float.NaN
  private var surfaceWidth = Float.NaN
  private var surfaceHeight = Float.NaN
  private var capsuleLeading = 0f
  private var capsuleTrailing = 0f

  private var activePointerId = MotionEvent.INVALID_POINTER_ID
  private var downX = 0f
  private var downY = 0f
  private var pressedIndex = 0
  private var isDraggingSelection = false
  private var velocityTracker: VelocityTracker? = null

  private var animatingIconIndex: Int? = null
  private var iconFrameIndex = 0
  private var iconAnimationRunnable: Runnable? = null

  var expandedHorizontalInset = 12f
    set(value) {
      field = value
      moveSurfaceToCurrentTarget(animated = false)
    }

  var compactWidth = 352f
    set(value) {
      field = value
      moveSurfaceToCurrentTarget(animated = false)
    }

  var expandedHeight = 78f
    set(value) {
      field = value
      requestLayout()
    }

  var compactHeight = 70f
    set(value) {
      field = value
      requestLayout()
    }

  var animationFrameDuration = 0.034

  var selectionDragEnabled = true
    set(value) {
      field = value
      if (!value) cancelGesture()
    }

  private val surfaceLeftProperty = floatProperty(
    "surfaceLeft",
    { surfaceLeft },
    { surfaceLeft = it }
  )
  private val surfaceTopProperty = floatProperty(
    "surfaceTop",
    { surfaceTop },
    { surfaceTop = it }
  )
  private val surfaceWidthProperty = floatProperty(
    "surfaceWidth",
    { surfaceWidth },
    { surfaceWidth = it }
  )
  private val surfaceHeightProperty = floatProperty(
    "surfaceHeight",
    { surfaceHeight },
    { surfaceHeight = it }
  )
  private val capsuleLeadingProperty = floatProperty(
    "capsuleLeading",
    { capsuleLeading },
    { capsuleLeading = it }
  )
  private val capsuleTrailingProperty = floatProperty(
    "capsuleTrailing",
    { capsuleTrailing },
    { capsuleTrailing = it }
  )

  private val surfaceLeftSpring = SpringAnimation(this, surfaceLeftProperty)
  private val surfaceTopSpring = SpringAnimation(this, surfaceTopProperty)
  private val surfaceWidthSpring = SpringAnimation(this, surfaceWidthProperty)
  private val surfaceHeightSpring = SpringAnimation(this, surfaceHeightProperty)
  private val capsuleLeadingSpring = SpringAnimation(this, capsuleLeadingProperty).apply {
    setMinimumVisibleChange(0.0005f)
  }
  private val capsuleTrailingSpring = SpringAnimation(this, capsuleTrailingProperty).apply {
    setMinimumVisibleChange(0.0005f)
  }

  init {
    clipChildren = false
    clipToPadding = false
    isClickable = true
    importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO

    surfaceView.clipChildren = true
    surfaceView.clipToPadding = false
    surfaceView.importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    surfaceView.elevation = dp(8f)

    selectionView.isClickable = false
    selectionView.importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO

    itemsRow.orientation = LinearLayout.HORIZONTAL
    itemsRow.importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO

    surfaceView.addView(selectionView)
    surfaceView.addView(itemsRow)
    addView(surfaceView)
    updateColors()

    ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets ->
      moveSurfaceToCurrentTarget(animated = false)
      insets
    }
  }

  fun setItems(definitions: List<ExpoNativeCompactTabItem>) {
    val changed = definitions.size != itemDefinitions.size ||
      definitions.zip(itemDefinitions).any { (next, current) ->
        next.key != current.key ||
          next.label != current.label ||
          next.imageUri != current.imageUri ||
          next.animationFrameUris != current.animationFrameUris ||
          next.accessibilityLabel != current.accessibilityLabel
      }

    if (!changed) return
    stopIconAnimation(resetToRestingFrame = false)
    itemDefinitions = definitions
    animationFrames = MutableList(definitions.size) { emptyList() }
    imageLoadGeneration += 1
    val generation = imageLoadGeneration

    itemViews.clear()
    itemsRow.removeAllViews()

    definitions.forEachIndexed { index, definition ->
      val itemView = TabItemView(context).apply {
        setLabel(definition.label)
        contentDescription = definition.accessibilityLabel ?: definition.label
        setCompact(isCompact)
        setOnClickListener { commitSelection(index, allowReselection = true) }
      }
      itemViews += itemView
      itemsRow.addView(
        itemView,
        LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f)
      )

      val frameUris = if (definition.animationFrameUris.isEmpty()) {
        listOf(definition.imageUri)
      } else {
        definition.animationFrameUris
      }
      loadFrames(frameUris, index, generation)
    }

    selectedIndex = selectedIndex.coerceIn(0, max(definitions.lastIndex, 0))
    previewIndex = selectedIndex
    setCapsuleImmediately(selectedIndex)
    updateItemStates(selectedIndex)
    requestLayout()
  }

  fun setSelectedIndex(index: Int) {
    if (itemDefinitions.isEmpty()) {
      selectedIndex = max(index, 0)
      previewIndex = selectedIndex
      return
    }

    val clamped = index.coerceIn(0, itemDefinitions.lastIndex)
    if (selectedIndex == clamped) return
    selectedIndex = clamped
    previewIndex = clamped
    animateCapsuleTo(clamped)
    updateItemStates(clamped)
    playIconAnimation(clamped)
  }

  fun setCompact(compact: Boolean) {
    if (isCompact == compact) return
    isCompact = compact
    itemViews.forEach { it.setCompact(compact) }
    moveSurfaceToCurrentTarget(animated = true)
  }

  fun setTintColor(color: Color?) {
    selectedTint = color?.let(ColorCompat::toArgb)
      ?: resolveThemeColor(android.R.attr.colorAccent, Color.rgb(255, 90, 54))
    updateItemStates(previewIndex)
  }

  fun setInactiveTintColor(color: Color?) {
    inactiveTint = color?.let(ColorCompat::toArgb) ?: Color.rgb(142, 142, 147)
    updateItemStates(previewIndex)
  }

  override fun onConfigurationChanged(newConfig: Configuration?) {
    super.onConfigurationChanged(newConfig)
    updateColors()
  }

  override fun onDetachedFromWindow() {
    super.onDetachedFromWindow()
    cancelGesture()
    stopIconAnimation(resetToRestingFrame = false)
    allSprings().forEach { it.cancel() }
  }

  override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
    super.onSizeChanged(width, height, oldWidth, oldHeight)
    if (width != oldWidth || height != oldHeight) {
      moveSurfaceToCurrentTarget(animated = false)
    }
  }

  override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
    if (!surfaceLeft.isFinite()) {
      applySurfaceGeometry(targetSurfaceGeometry())
    }

    layoutNativeChildren()
  }

  private fun refreshNativeLayout() {
    if (width > 0 && height > 0 && surfaceLeft.isFinite()) {
      layoutNativeChildren()
      invalidate()
    } else {
      requestLayout()
    }
  }

  private fun layoutNativeChildren() {
    val surfaceLeftInt = surfaceLeft.roundToInt()
    val surfaceTopInt = surfaceTop.roundToInt()
    val surfaceRightInt = (surfaceLeft + max(surfaceWidth, 0f)).roundToInt()
    val surfaceBottomInt = (surfaceTop + max(surfaceHeight, 0f)).roundToInt()
    surfaceView.measure(
      MeasureSpec.makeMeasureSpec(max(surfaceRightInt - surfaceLeftInt, 0), MeasureSpec.EXACTLY),
      MeasureSpec.makeMeasureSpec(max(surfaceBottomInt - surfaceTopInt, 0), MeasureSpec.EXACTLY)
    )
    surfaceView.layout(surfaceLeftInt, surfaceTopInt, surfaceRightInt, surfaceBottomInt)

    val localWidth = surfaceView.width
    val localHeight = surfaceView.height
    val capsuleInset = dp(4f).roundToInt()
    val capsuleLeft = (capsuleLeading * localWidth).roundToInt() + capsuleInset
    val capsuleRight = (capsuleTrailing * localWidth).roundToInt() - capsuleInset
    selectionView.layout(
      capsuleLeft.coerceAtMost(capsuleRight),
      capsuleInset,
      capsuleRight.coerceAtLeast(capsuleLeft),
      max(localHeight - capsuleInset, capsuleInset)
    )
    itemsRow.layout(0, 0, localWidth, localHeight)
    updateRoundedBackgrounds()
  }

  override fun onInterceptTouchEvent(event: MotionEvent): Boolean {
    if (!selectionDragEnabled || itemDefinitions.isEmpty()) return false
    if (event.actionMasked == MotionEvent.ACTION_DOWN) {
      return isPointInsideSurface(event.x, event.y)
    }
    return activePointerId != MotionEvent.INVALID_POINTER_ID
  }

  override fun onTouchEvent(event: MotionEvent): Boolean {
    if (!selectionDragEnabled || itemDefinitions.isEmpty()) return super.onTouchEvent(event)

    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        if (!isPointInsideSurface(event.x, event.y)) return false
        activePointerId = event.getPointerId(0)
        downX = event.x
        downY = event.y
        pressedIndex = indexForX(event.x)
        previewIndex = pressedIndex
        isDraggingSelection = false
        velocityTracker?.recycle()
        velocityTracker = VelocityTracker.obtain().also { it.addMovement(event) }
        animateCapsuleTo(pressedIndex, pressed = true)
        updateItemStates(pressedIndex)
        parent?.requestDisallowInterceptTouchEvent(true)
        return true
      }

      MotionEvent.ACTION_POINTER_UP -> {
        if (event.getPointerId(event.actionIndex) == activePointerId) {
          finishGesture(cancelled = true)
        }
        return true
      }

      MotionEvent.ACTION_MOVE -> {
        val pointerIndex = event.findPointerIndex(activePointerId)
        if (pointerIndex < 0) {
          finishGesture(cancelled = true)
          return true
        }
        velocityTracker?.addMovement(event)
        val x = event.getX(pointerIndex)
        val y = event.getY(pointerIndex)
        if (!isDraggingSelection && hypot(x - downX, y - downY) > touchSlop) {
          isDraggingSelection = true
          capsuleLeadingSpring.cancel()
          capsuleTrailingSpring.cancel()
        }
        if (isDraggingSelection) {
          velocityTracker?.computeCurrentVelocity(1000)
          updateDraggedCapsule(x, velocityTracker?.getXVelocity(activePointerId) ?: 0f)
        }
        return true
      }

      MotionEvent.ACTION_UP -> {
        velocityTracker?.addMovement(event)
        velocityTracker?.computeCurrentVelocity(1000)
        val releaseVelocity = velocityTracker?.getXVelocity(activePointerId) ?: 0f
        val releaseX = event.x
        if (isDraggingSelection) {
          val projectedX = releaseX + releaseVelocity * RELEASE_PROJECTION_SECONDS
          val targetIndex = indexForX(projectedX)
          if (targetIndex == selectedIndex) {
            previewIndex = selectedIndex
            updateItemStates(selectedIndex)
            animateCapsuleTo(selectedIndex, initialVelocity = releaseVelocity)
          } else {
            commitSelection(
              targetIndex,
              allowReselection = false,
              initialVelocity = releaseVelocity
            )
          }
        } else if (isPointInsideSurface(releaseX, event.y)) {
          performClick()
          commitSelection(indexForX(releaseX), allowReselection = true)
        } else {
          restoreCommittedSelection()
        }
        clearGestureState()
        return true
      }

      MotionEvent.ACTION_CANCEL -> {
        finishGesture(cancelled = true)
        return true
      }
    }

    return super.onTouchEvent(event)
  }

  override fun performClick(): Boolean {
    super.performClick()
    return true
  }

  private fun commitSelection(
    index: Int,
    allowReselection: Boolean,
    initialVelocity: Float = 0f
  ) {
    if (itemDefinitions.isEmpty()) return
    val clamped = index.coerceIn(0, itemDefinitions.lastIndex)
    val isReselection = clamped == selectedIndex
    selectedIndex = clamped
    previewIndex = clamped
    updateItemStates(clamped)
    animateCapsuleTo(clamped, initialVelocity = initialVelocity)

    if (!isReselection || allowReselection) {
      playIconAnimation(clamped)
      performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
      onTabSelected(mapOf("index" to clamped))
    }
  }

  private fun updateDraggedCapsule(pointerX: Float, velocityX: Float) {
    if (itemDefinitions.isEmpty() || surfaceWidth <= 0f) return
    val localFraction = ((pointerX - surfaceLeft) / surfaceWidth).coerceIn(0f, 1f)
    val itemFraction = 1f / itemDefinitions.size
    val stretch = min(abs(velocityX) * 0.000018f, itemFraction * 0.14f)
    val directionalShift = min(abs(velocityX) * 0.000010f, itemFraction * 0.08f)
    val shiftedCenter = when {
      velocityX > 0f -> localFraction + directionalShift
      velocityX < 0f -> localFraction - directionalShift
      else -> localFraction
    }.coerceIn(itemFraction / 2f, 1f - itemFraction / 2f)

    capsuleLeading = (shiftedCenter - itemFraction / 2f - stretch).coerceAtLeast(0f)
    capsuleTrailing = (shiftedCenter + itemFraction / 2f + stretch).coerceAtMost(1f)
    refreshNativeLayout()

    val nearest = indexForX(pointerX)
    if (nearest != previewIndex) {
      previewIndex = nearest
      updateItemStates(nearest)
      performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
    }
  }

  private fun animateCapsuleTo(
    index: Int,
    pressed: Boolean = false,
    initialVelocity: Float = 0f
  ) {
    if (itemDefinitions.isEmpty()) return
    val clamped = index.coerceIn(0, itemDefinitions.lastIndex)
    val targetLeading = clamped.toFloat() / itemDefinitions.size
    val targetTrailing = (clamped + 1f) / itemDefinitions.size
    val movingRight = targetLeading > capsuleLeading
    val animationsEnabled = animationsEnabled()

    if (!animationsEnabled) {
      capsuleLeadingSpring.cancel()
      capsuleTrailingSpring.cancel()
      capsuleLeading = targetLeading
      capsuleTrailing = targetTrailing
      refreshNativeLayout()
      return
    }

    val normalizedVelocity = if (surfaceWidth > 0f) initialVelocity / surfaceWidth else 0f
    val frontStiffness = if (pressed) 900f else 820f
    val rearStiffness = if (pressed) 720f else 520f
    configureCapsuleSpring(
      capsuleLeadingSpring,
      targetLeading,
      if (movingRight) rearStiffness else frontStiffness,
      normalizedVelocity
    )
    configureCapsuleSpring(
      capsuleTrailingSpring,
      targetTrailing,
      if (movingRight) frontStiffness else rearStiffness,
      normalizedVelocity
    )
    capsuleLeadingSpring.start()
    capsuleTrailingSpring.start()
  }

  private fun configureCapsuleSpring(
    animation: SpringAnimation,
    finalPosition: Float,
    stiffness: Float,
    initialVelocity: Float
  ) {
    animation.cancel()
    animation.spring = SpringForce(finalPosition).apply {
      this.stiffness = stiffness
      dampingRatio = if (initialVelocity == 0f) 0.88f else 0.82f
    }
    animation.setStartVelocity(initialVelocity)
  }

  private fun setCapsuleImmediately(index: Int) {
    capsuleLeadingSpring.cancel()
    capsuleTrailingSpring.cancel()
    if (itemDefinitions.isEmpty()) {
      capsuleLeading = 0f
      capsuleTrailing = 0f
    } else {
      val clamped = index.coerceIn(0, itemDefinitions.lastIndex)
      capsuleLeading = clamped.toFloat() / itemDefinitions.size
      capsuleTrailing = (clamped + 1f) / itemDefinitions.size
    }
    refreshNativeLayout()
  }

  private fun updateItemStates(activeIndex: Int) {
    itemViews.forEachIndexed { index, itemView ->
      val active = index == activeIndex
      itemView.setTint(if (active) selectedTint else inactiveTint)
      itemView.isSelected = index == selectedIndex
    }
  }

  private fun moveSurfaceToCurrentTarget(animated: Boolean) {
    if (width <= 0 || height <= 0) {
      requestLayout()
      return
    }
    val target = targetSurfaceGeometry()
    if (!animated || !animationsEnabled() || !surfaceLeft.isFinite()) {
      allSurfaceSprings().forEach { it.cancel() }
      applySurfaceGeometry(target)
      return
    }

    configureSurfaceSpring(surfaceLeftSpring, target.left)
    configureSurfaceSpring(surfaceTopSpring, target.top)
    configureSurfaceSpring(surfaceWidthSpring, target.width)
    configureSurfaceSpring(surfaceHeightSpring, target.height)
    allSurfaceSprings().forEach { it.start() }
  }

  private fun targetSurfaceGeometry(): SurfaceGeometry {
    val expandedTargetWidth = max(width - dp(expandedHorizontalInset) * 2f, 0f)
    val targetWidth = if (isCompact) {
      min(dp(compactWidth), expandedTargetWidth)
    } else {
      expandedTargetWidth
    }
    val opticalInset = dp(if (isCompact) 21f else 18f)
    val resolvedWidth = max(targetWidth - min(opticalInset, targetWidth / 2f) * 2f, 0f)
    val resolvedHeight = dp(if (isCompact) 44f else 58f)
    @Suppress("DEPRECATION")
    val navigationBottom = rootWindowInsets?.stableInsetBottom?.toFloat() ?: 0f
    val compactLift = if (isCompact) dp(6f) else 0f
    val bottomOffset = max(navigationBottom, dp(12f)) + compactLift
    return SurfaceGeometry(
      left = (width - resolvedWidth) / 2f,
      top = height - bottomOffset - resolvedHeight,
      width = resolvedWidth,
      height = resolvedHeight
    )
  }

  private fun applySurfaceGeometry(target: SurfaceGeometry) {
    surfaceLeft = target.left
    surfaceTop = target.top
    surfaceWidth = target.width
    surfaceHeight = target.height
    refreshNativeLayout()
  }

  private fun configureSurfaceSpring(animation: SpringAnimation, finalPosition: Float) {
    animation.cancel()
    animation.spring = SpringForce(finalPosition).apply {
      stiffness = 650f
      dampingRatio = 1f
    }
  }

  private fun updateRoundedBackgrounds() {
    surfaceView.background = roundedDrawable(
      fillColor = surfaceColor(),
      strokeColor = borderColor(),
      radius = surfaceView.height / 2f,
      strokeWidth = dp(1f).roundToInt()
    )
    selectionView.background = roundedDrawable(
      fillColor = selectionColor(),
      radius = selectionView.height / 2f
    )
  }

  private fun updateColors() {
    updateRoundedBackgrounds()
    updateItemStates(previewIndex)
  }

  private fun surfaceColor(): Int = if (isDarkMode()) {
    Color.argb(240, 18, 18, 18)
  } else {
    Color.argb(240, 250, 250, 250)
  }

  private fun borderColor(): Int = if (isDarkMode()) {
    Color.argb(26, 255, 255, 255)
  } else {
    Color.argb(26, 0, 0, 0)
  }

  private fun selectionColor(): Int = if (isDarkMode()) {
    Color.argb(36, 255, 255, 255)
  } else {
    Color.argb(20, 0, 0, 0)
  }

  private fun roundedDrawable(
    fillColor: Int,
    strokeColor: Int? = null,
    radius: Float,
    strokeWidth: Int = 0
  ) = GradientDrawable().apply {
    shape = GradientDrawable.RECTANGLE
    cornerRadius = max(radius, 0f)
    setColor(fillColor)
    if (strokeColor != null && strokeWidth > 0) setStroke(strokeWidth, strokeColor)
  }

  private fun loadFrames(uris: List<String>, itemIndex: Int, generation: Int) {
    if (uris.isEmpty()) return
    val loaded = arrayOfNulls<Bitmap>(uris.size)
    var remaining = uris.size

    uris.forEachIndexed { frameIndex, uri ->
      BitmapLoader.load(context, uri) { bitmap ->
        if (generation != imageLoadGeneration || !animationFrames.indices.contains(itemIndex)) {
          return@load
        }
        loaded[frameIndex] = bitmap
        remaining -= 1
        if (remaining == 0) {
          val frames = loaded.filterNotNull()
          animationFrames[itemIndex] = frames
          frames.firstOrNull()?.let { setIconBitmap(itemIndex, it) }
        }
      }
    }
  }

  private fun playIconAnimation(index: Int) {
    if (!animationsEnabled() || !animationFrames.indices.contains(index)) return
    val frames = animationFrames[index]
    if (frames.size <= 1) return
    stopIconAnimation(resetToRestingFrame = true)
    animatingIconIndex = index
    iconFrameIndex = 0
    setIconBitmap(index, frames[0])

    val runnable = object : Runnable {
      override fun run() {
        val activeIndex = animatingIconIndex ?: return
        if (!animationsEnabled() || !animationFrames.indices.contains(activeIndex)) {
          stopIconAnimation(resetToRestingFrame = true)
          return
        }
        iconFrameIndex += 1
        val activeFrames = animationFrames[activeIndex]
        if (iconFrameIndex >= activeFrames.size) {
          stopIconAnimation(resetToRestingFrame = true)
          return
        }
        setIconBitmap(activeIndex, activeFrames[iconFrameIndex])
        mainHandler.postDelayed(this, max((animationFrameDuration * 1000).roundToInt(), 1).toLong())
      }
    }
    iconAnimationRunnable = runnable
    mainHandler.postDelayed(runnable, max((animationFrameDuration * 1000).roundToInt(), 1).toLong())
  }

  private fun stopIconAnimation(resetToRestingFrame: Boolean) {
    iconAnimationRunnable?.let(mainHandler::removeCallbacks)
    iconAnimationRunnable = null
    val activeIndex = animatingIconIndex
    if (resetToRestingFrame && activeIndex != null && animationFrames.indices.contains(activeIndex)) {
      animationFrames[activeIndex].firstOrNull()?.let { setIconBitmap(activeIndex, it) }
    }
    animatingIconIndex = null
    iconFrameIndex = 0
  }

  private fun setIconBitmap(index: Int, bitmap: Bitmap) {
    itemViews.getOrNull(index)?.setBitmap(bitmap)
  }

  private fun finishGesture(cancelled: Boolean) {
    if (cancelled) restoreCommittedSelection()
    clearGestureState()
  }

  private fun restoreCommittedSelection() {
    previewIndex = selectedIndex
    updateItemStates(selectedIndex)
    animateCapsuleTo(selectedIndex)
  }

  private fun cancelGesture() {
    if (activePointerId != MotionEvent.INVALID_POINTER_ID) {
      restoreCommittedSelection()
    }
    clearGestureState()
  }

  private fun clearGestureState() {
    velocityTracker?.recycle()
    velocityTracker = null
    activePointerId = MotionEvent.INVALID_POINTER_ID
    isDraggingSelection = false
    parent?.requestDisallowInterceptTouchEvent(false)
  }

  private fun indexForX(parentX: Float): Int {
    if (itemDefinitions.isEmpty() || surfaceWidth <= 0f) return 0
    val fraction = ((parentX - surfaceLeft) / surfaceWidth).coerceIn(0f, 0.999999f)
    return (fraction * itemDefinitions.size).toInt().coerceIn(0, itemDefinitions.lastIndex)
  }

  private fun isPointInsideSurface(x: Float, y: Float): Boolean {
    return x >= surfaceLeft && x <= surfaceLeft + surfaceWidth &&
      y >= surfaceTop && y <= surfaceTop + surfaceHeight
  }

  private fun animationsEnabled(): Boolean {
    return ValueAnimator.areAnimatorsEnabled()
  }

  private fun isDarkMode(): Boolean {
    val interfaceStyleResource = resources.getIdentifier(
      "expo_system_ui_user_interface_style",
      "string",
      context.packageName
    )
    if (interfaceStyleResource != 0) {
      when (resources.getString(interfaceStyleResource).lowercase()) {
        "dark" -> return true
        "light" -> return false
      }
    }

    return resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
      Configuration.UI_MODE_NIGHT_YES
  }

  private fun resolveThemeColor(attribute: Int, fallback: Int): Int {
    val typedValue = android.util.TypedValue()
    return if (context.theme.resolveAttribute(attribute, typedValue, true)) {
      typedValue.data
    } else {
      fallback
    }
  }

  private fun dp(value: Float): Float = value * density

  private fun floatProperty(
    name: String,
    getter: () -> Float,
    setter: (Float) -> Unit
  ) = object : FloatPropertyCompat<ExpoNativeCompactTabsView>(name) {
    override fun getValue(view: ExpoNativeCompactTabsView): Float = getter()

    override fun setValue(view: ExpoNativeCompactTabsView, value: Float) {
      setter(value)
      refreshNativeLayout()
    }
  }

  private fun allSurfaceSprings() = listOf(
    surfaceLeftSpring,
    surfaceTopSpring,
    surfaceWidthSpring,
    surfaceHeightSpring
  )

  private fun allSprings() = allSurfaceSprings() + listOf(
    capsuleLeadingSpring,
    capsuleTrailingSpring
  )

  private data class SurfaceGeometry(
    val left: Float,
    val top: Float,
    val width: Float,
    val height: Float
  )

  private inner class TabItemView(context: Context) : LinearLayout(context) {
    private val iconView = ImageView(context)
    private val labelView = TextView(context)

    init {
      orientation = VERTICAL
      gravity = android.view.Gravity.CENTER
      isClickable = true
      isFocusable = true
      importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
      context.obtainStyledAttributes(
        intArrayOf(android.R.attr.selectableItemBackgroundBorderless)
      ).let { attributes ->
        foreground = attributes.getDrawable(0)
        attributes.recycle()
      }

      iconView.scaleType = ImageView.ScaleType.CENTER_INSIDE
      iconView.importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
      addView(iconView, LayoutParams(dp(28f).roundToInt(), dp(28f).roundToInt()))

      labelView.includeFontPadding = false
      labelView.gravity = android.view.Gravity.CENTER
      labelView.textSize = 12f
      labelView.typeface = Typeface.create(Typeface.DEFAULT, Typeface.NORMAL)
      labelView.importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
      addView(
        labelView,
        LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
          topMargin = dp(2f).roundToInt()
        }
      )
    }

    override fun getAccessibilityClassName(): CharSequence = android.widget.Button::class.java.name

    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo?) {
      super.onInitializeAccessibilityNodeInfo(info)
      info?.isSelected = isSelected
    }

    fun setLabel(label: String) {
      labelView.text = label
    }

    fun setCompact(compact: Boolean) {
      labelView.visibility = if (compact) GONE else VISIBLE
    }

    fun setTint(color: Int) {
      iconView.imageTintList = ColorStateList.valueOf(color)
      labelView.setTextColor(color)
    }

    fun setBitmap(bitmap: Bitmap) {
      iconView.setImageBitmap(bitmap)
    }
  }

  private object BitmapLoader {
    private val executor = Executors.newFixedThreadPool(3)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val cache = object : LruCache<String, Bitmap>(16 * 1024 * 1024) {
      override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
    }

    fun load(context: Context, uriString: String, completion: (Bitmap?) -> Unit) {
      cache.get(uriString)?.let {
        completion(it)
        return
      }

      executor.execute {
        val bitmap = runCatching { decode(context, uriString) }.getOrNull()
        if (bitmap != null) cache.put(uriString, bitmap)
        mainHandler.post { completion(bitmap) }
      }
    }

    private fun decode(context: Context, uriString: String): Bitmap? {
      if (uriString.startsWith("data:")) {
        val encoded = uriString.substringAfter(',', "")
        if (encoded.isEmpty()) return null
        val bytes = Base64.decode(encoded, Base64.DEFAULT)
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
      }

      val uri = Uri.parse(uriString)
      return when (uri.scheme?.lowercase()) {
        "http", "https" -> decodeNetwork(uriString)
        "file", "content", "android.resource" -> context.contentResolver
          .openInputStream(uri)
          ?.use(BitmapFactory::decodeStream)
        "asset", "assets" -> context.assets
          .open(uriString.substringAfter("://").trimStart('/'))
          .use(BitmapFactory::decodeStream)
        null, "" -> {
          val resourceId = context.resources.getIdentifier(uriString, "drawable", context.packageName)
          if (resourceId == 0) null else BitmapFactory.decodeResource(context.resources, resourceId)
        }
        else -> null
      }
    }

    private fun decodeNetwork(uriString: String): Bitmap? {
      val connection = URL(uriString).openConnection() as HttpURLConnection
      connection.connectTimeout = 8_000
      connection.readTimeout = 8_000
      connection.instanceFollowRedirects = true
      return try {
        connection.inputStream.use(BitmapFactory::decodeStream)
      } finally {
        connection.disconnect()
      }
    }
  }

  companion object {
    private const val RELEASE_PROJECTION_SECONDS = 0.08f
  }
}

import 'package:imcodec/imcodec.dart' as imcodec;

/// Describes what a container does with a displayed frame before the next one.
enum AnimationFrameDisposal {
  /// Leaves the displayed pixels in place.
  keep,

  /// Restores the frame area to the animation background.
  background,

  /// Restores the canvas state captured before the frame was drawn.
  previous,
}

/// Identifies the encoded rectangle from which a complete canvas frame came.
final class AnimationFrameArea {
  /// Horizontal offset in canvas pixels.
  final int x;

  /// Vertical offset in canvas pixels.
  final int y;

  /// Horizontal extent in pixels.
  final int width;

  /// Vertical extent in pixels.
  final int height;

  /// Creates a non-negative animation-frame rectangle with positive extents.
  factory AnimationFrameArea({
    required int x,
    required int y,
    required int width,
    required int height,
  }) {
    if (x < 0 || y < 0) {
      throw ArgumentError('Animation frame offsets must not be negative');
    }
    if (width < 1 || height < 1) {
      throw ArgumentError('Animation frame dimensions must be positive');
    }
    return AnimationFrameArea._(
      x: x,
      y: y,
      width: width,
      height: height,
    );
  }

  /// Creates an area covering a complete canvas.
  factory AnimationFrameArea.full({
    required int width,
    required int height,
  }) => AnimationFrameArea(x: 0, y: 0, width: width, height: height);

  /// Stores already validated rectangle values.
  const AnimationFrameArea._({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });
}

/// Stores one fully composited straight-alpha RGBA animation frame.
final class RasterAnimationFrame {
  /// Complete canvas pixels displayed for this frame.
  ///
  /// The caller owns this Imcodec image and may edit its mutable byte buffer.
  final imcodec.Image image;

  /// Presentation time before advancing to the next frame.
  final Duration duration;

  /// Encoded source rectangle retained for inspection and diagnostics.
  final AnimationFrameArea sourceArea;

  /// Encoded disposal behavior retained for inspection and diagnostics.
  final AnimationFrameDisposal disposal;

  /// Creates one frame, defaulting its source area to the complete image.
  factory RasterAnimationFrame({
    required imcodec.Image image,
    required Duration duration,
    AnimationFrameArea? sourceArea,
    AnimationFrameDisposal disposal = AnimationFrameDisposal.keep,
  }) {
    if (duration.isNegative) {
      throw ArgumentError.value(duration, 'duration', 'Frame duration must not be negative');
    }
    return RasterAnimationFrame._(
      image: image,
      duration: duration,
      sourceArea: sourceArea ?? AnimationFrameArea.full(width: image.width, height: image.height),
      disposal: disposal,
    );
  }

  /// Stores already validated frame values.
  const RasterAnimationFrame._({
    required this.image,
    required this.duration,
    required this.sourceArea,
    required this.disposal,
  });
}

/// Stores an editable ordered sequence of complete raster frames.
final class RasterAnimation {
  /// Logical canvas width in pixels.
  final int width;

  /// Logical canvas height in pixels.
  final int height;

  /// Ordered frame values.
  final List<RasterAnimationFrame> frames;

  /// Encoded loop value: `null` means no loop extension and zero means forever.
  ///
  /// Positive values retain the container's finite loop count.
  final int? loopCount;

  /// Creates and validates an editable raster sequence.
  RasterAnimation({
    required this.width,
    required this.height,
    required List<RasterAnimationFrame> frames,
    this.loopCount,
  }) : frames = List<RasterAnimationFrame>.unmodifiable(frames) {
    if (width < 1 || height < 1) {
      throw ArgumentError('Animation dimensions must be positive and non-zero');
    }
    if (this.frames.isEmpty) {
      throw ArgumentError.value(frames, 'frames', 'An animation needs at least one frame');
    }
    final int? configuredLoopCount = loopCount;
    if (configuredLoopCount != null && (configuredLoopCount < 0 || configuredLoopCount > 0xffff)) {
      throw RangeError.range(
        configuredLoopCount,
        0,
        0xffff,
        'loopCount',
      );
    }
    for (final RasterAnimationFrame frame in this.frames) {
      if (frame.image.width != width || frame.image.height != height) {
        throw ArgumentError.value(
          frame.image,
          'frames',
          'Every frame image must match the $width x $height animation canvas',
        );
      }
      final AnimationFrameArea area = frame.sourceArea;
      if (area.x < 0 || area.y < 0 || area.width < 1 || area.height < 1 || area.x + area.width > width || area.y + area.height > height) {
        throw ArgumentError.value(area, 'frames', 'A frame source area exceeds the animation canvas');
      }
    }
  }

  /// Total presentation time of one pass through every frame.
  Duration get duration => frames.fold(Duration.zero, (total, frame) => total + frame.duration);
}

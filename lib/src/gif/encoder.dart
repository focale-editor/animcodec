part of '../gif.dart';

/// Encodes a complete sequence through [GifAnimationStreamEncoder].
Uint8List _encodeGif(
  RasterAnimation animation,
  GifAnimationEncodeOptions options,
) {
  final GifAnimationStreamEncoder encoder = GifAnimationStreamEncoder(
    width: animation.width,
    height: animation.height,
    loopCount: animation.loopCount,
    options: options,
  );
  animation.frames.forEach(encoder.add);
  return encoder.close();
}

/// Encodes complete RGBA canvas frames one at a time as a GIF89a animation.
///
/// Only two canvases are retained at any time, so a long sequence can be
/// rendered and encoded frame by frame without holding every frame in memory.
///
/// Each frame after the first is written as the smallest rectangle containing
/// its changes, and pixels that already show the right colour inside that
/// rectangle are written as transparent so the previous frame shows through.
/// Pixels that must become transparent cannot be expressed by drawing, since a
/// transparent GIF pixel leaves what is underneath: the previous frame is then
/// given the "restore to background" disposal over a rectangle enlarged to
/// cover them. That decision needs the next frame, which is why one encoded
/// frame is held back until the following one arrives or [close] is called.
final class GifAnimationStreamEncoder {
  /// Logical canvas width in pixels.
  final int width;

  /// Logical canvas height in pixels.
  final int height;

  /// Settings used to quantize frames and bound the output.
  final GifAnimationEncodeOptions options;

  /// Destination of the encoded container.
  final _GifWriter _output;

  /// Frame whose disposal is still undecided.
  _PendingGifFrame? _pending;

  /// Number of frames accepted so far.
  int _frameCount = 0;

  /// Whether [close] has already produced the encoded bytes.
  bool _closed = false;

  /// Whether the first frame leaves any pixel transparent.
  bool _firstFrameHasTransparency = false;

  /// Starts a GIF animation with a [width] by [height] canvas.
  ///
  /// [loopCount] follows [RasterAnimation.loopCount]: `null` writes no loop
  /// extension and zero loops forever.
  GifAnimationStreamEncoder({
    required this.width,
    required this.height,
    int? loopCount,
    this.options = const GifAnimationEncodeOptions(),
  }) : _output = _GifWriter(maxBytes: options.maxOutputBytes) {
    options.validate();
    if (width < 1 || height < 1) {
      throw ArgumentError('Animation dimensions must be positive and non-zero');
    }
    if (width > 0xffff || height > 0xffff) {
      throw const AnimationCodecException(
        message: 'GIF dimensions may not exceed 65535 pixels',
        failure: AnimationCodecFailure.limitExceeded,
      );
    }
    if (loopCount != null && (loopCount < 0 || loopCount > 0xffff)) {
      throw RangeError.range(loopCount, 0, 0xffff, 'loopCount');
    }
    _output
      ..writeBytes(const [0x47, 0x49, 0x46, 0x38, 0x39, 0x61])
      ..writeUint16(width)
      ..writeUint16(height)
      // No global colour table: every frame carries the palette Imcodec chose
      // for its own pixels, and a missing table makes the background
      // transparent in every decoder.
      ..writeByte(0x70)
      ..writeByte(0)
      ..writeByte(0);
    if (loopCount != null) {
      _output
        ..writeBytes(const [0x21, 0xff, 0x0b])
        ..writeBytes('NETSCAPE2.0'.codeUnits)
        ..writeBytes(const [0x03, 0x01])
        ..writeUint16(loopCount)
        ..writeByte(0);
    }
  }

  /// Appends [frame], whose image must match the animation canvas.
  void add(RasterAnimationFrame frame) {
    if (_closed) {
      throw StateError('The GIF animation encoder is already closed');
    }
    if (frame.image.width != width || frame.image.height != height) {
      throw ArgumentError.value(
        frame.image,
        'frame',
        'Every frame image must match the $width x $height animation canvas',
      );
    }
    final int delayCentiseconds = _durationCentiseconds(frame.duration);
    final Uint8List canvas = _normalizedCanvas(frame.image.bytes);
    final _PendingGifFrame? previous = _pending;
    final Uint8List stateBefore;
    if (previous == null) {
      stateBefore = Uint8List(canvas.length);
      _firstFrameHasTransparency = _hasTransparency(canvas);
    } else {
      final _GifRectangle? cleared = _newlyTransparentBounds(
        previous.canvas,
        canvas,
      );
      if (cleared != null) {
        previous
          ..area = previous.area.union(cleared)
          ..restoreToBackground = true;
      }
      _write(previous, index: _frameCount - 1);
      stateBefore = previous.restoreToBackground ? (previous.canvas..fillArea(previous.area, width)) : previous.canvas;
    }
    _pending = _PendingGifFrame(
      canvas: canvas,
      stateBefore: stateBefore,
      area: previous == null ? _GifRectangle(0, 0, width, height) : _changedBounds(stateBefore, canvas),
      delayCentiseconds: delayCentiseconds,
    );
    _frameCount++;
  }

  /// Writes the last frame and returns the complete GIF bytes.
  Uint8List close() {
    if (_closed) {
      throw StateError('The GIF animation encoder is already closed');
    }
    final _PendingGifFrame? last = _pending;
    if (last == null) {
      throw StateError('An animation needs at least one frame');
    }
    if (_frameCount > 1 && _firstFrameHasTransparency) {
      // A decoder that replays the first frame over whatever the last one left
      // would otherwise show stale pixels through its transparent areas.
      last
        ..area = _GifRectangle(0, 0, width, height)
        ..restoreToBackground = true;
    }
    _write(last, index: _frameCount - 1);
    _pending = null;
    _closed = true;
    _output.writeByte(0x3b);
    return _output.takeBytes();
  }

  /// Copies [bytes], collapsing every pixel the GIF palette makes transparent.
  ///
  /// Pixels below the alpha threshold all become `0, 0, 0, 0`, so comparisons
  /// between frames ignore colour hidden behind transparency.
  Uint8List _normalizedCanvas(Uint8List bytes) {
    final Uint8List canvas = Uint8List.fromList(bytes);
    final imcodec.GifEncodeOptions frameOptions = options.frameOptions;
    if (!frameOptions.transparency) {
      return canvas;
    }
    for (int offset = 0; offset < canvas.length; offset += 4) {
      if (canvas[offset + 3] < frameOptions.alphaThreshold) {
        canvas.fillRange(offset, offset + 4, 0);
      }
    }
    return canvas;
  }

  /// Whether any pixel of a normalized [canvas] is transparent.
  bool _hasTransparency(Uint8List canvas) {
    if (!options.frameOptions.transparency) {
      return false;
    }
    for (int offset = 3; offset < canvas.length; offset += 4) {
      if (canvas[offset] == 0) {
        return true;
      }
    }
    return false;
  }

  /// Bounds of pixels transparent in [next] but visible in [current].
  _GifRectangle? _newlyTransparentBounds(Uint8List current, Uint8List next) {
    if (!options.frameOptions.transparency) {
      return null;
    }
    final _GifBoundsBuilder bounds = _GifBoundsBuilder();
    for (int y = 0; y < height; y++) {
      final int row = y * width;
      for (int x = 0; x < width; x++) {
        final int alphaOffset = (row + x) * 4 + 3;
        if (next[alphaOffset] == 0 && current[alphaOffset] != 0) {
          bounds.include(x, y);
        }
      }
    }
    return bounds.build();
  }

  /// Bounds of every pixel differing between [before] and [after].
  ///
  /// An unchanged frame still needs one image descriptor; it becomes a single
  /// transparent pixel that leaves the canvas untouched.
  _GifRectangle _changedBounds(Uint8List before, Uint8List after) {
    final _GifBoundsBuilder bounds = _GifBoundsBuilder();
    for (int y = 0; y < height; y++) {
      final int row = y * width;
      for (int x = 0; x < width; x++) {
        final int offset = (row + x) * 4;
        if (before[offset] != after[offset] || before[offset + 1] != after[offset + 1] || before[offset + 2] != after[offset + 2] || before[offset + 3] != after[offset + 3]) {
          bounds.include(x, y);
        }
      }
    }
    return bounds.build() ?? const _GifRectangle(0, 0, 1, 1);
  }

  /// Quantizes and writes [frame] with its final area and disposal.
  void _write(_PendingGifFrame frame, {required int index}) {
    final _GifRectangle area = frame.area;
    final Uint8List crop = Uint8List(area.width * area.height * 4);
    final bool transparency = options.frameOptions.transparency;
    for (int y = 0; y < area.height; y++) {
      final int sourceRow = (area.top + y) * width + area.left;
      final int targetRow = y * area.width;
      for (int x = 0; x < area.width; x++) {
        final int source = (sourceRow + x) * 4;
        final int target = (targetRow + x) * 4;
        final bool unchanged =
            frame.canvas[source] == frame.stateBefore[source] &&
            frame.canvas[source + 1] == frame.stateBefore[source + 1] &&
            frame.canvas[source + 2] == frame.stateBefore[source + 2] &&
            frame.canvas[source + 3] == frame.stateBefore[source + 3];
        // Already correct on screen: transparent leaves it there and costs
        // nothing to compress. The first frame draws over a transparent
        // canvas, where the same holds for every transparent source pixel.
        if (transparency && unchanged) {
          continue;
        }
        crop.setRange(target, target + 4, frame.canvas, source);
      }
    }

    final Uint8List staticBytes;
    try {
      staticBytes = imcodec.encodeGif(
        imcodec.Image.fromRgba(width: area.width, height: area.height, bytes: crop, copy: false),
        options: options.frameOptions,
      );
    } on Object catch (error) {
      throw AnimationCodecException(
        message: 'Could not encode GIF frame ${index + 1}',
        cause: error,
      );
    }
    final _ParsedGif staticGif = _ParsedGif.parse(
      bytes: staticBytes,
      options: GifAnimationDecodeOptions(
        maxEncodedBytes: math.max(staticBytes.length, 1),
        maxCanvasPixels: area.width * area.height,
        maxFrames: 1,
      ),
    );
    final _ParsedGifFrame encoded = staticGif.frames.single;
    final Uint8List palette = encoded.localColorTable ?? staticGif.globalColorTable ?? (throw const AnimationCodecException(message: 'Imcodec GIF frame has no colour table'));
    final int tableSizeBits = encoded.localColorTable == null ? staticGif.screenPacked & 0x07 : encoded.imagePacked & 0x07;
    final int? transparentIndex = encoded.control.transparentIndex;
    final int disposal = frame.restoreToBackground ? 2 : 1;
    _output
      ..writeBytes(const [0x21, 0xf9, 0x04])
      ..writeByte((disposal << 2) | (transparentIndex == null ? 0 : 1))
      ..writeUint16(frame.delayCentiseconds)
      ..writeByte(transparentIndex ?? 0)
      ..writeByte(0)
      ..writeByte(0x2c)
      ..writeUint16(area.left)
      ..writeUint16(area.top)
      ..writeUint16(area.width)
      ..writeUint16(area.height)
      // Keep only the table size: the interlace flag describes Imcodec's
      // stored row order, which the sub-blocks below are written in.
      ..writeByte(0x80 | (encoded.imagePacked & 0x40) | tableSizeBits)
      ..writeBytes(palette)
      ..writeByte(encoded.minimumCodeSize)
      ..writeBytes(encoded.imageSubBlocks);
  }
}

/// One encoded-frame candidate whose disposal depends on the next frame.
final class _PendingGifFrame {
  /// Normalized straight-alpha pixels displayed by this frame.
  final Uint8List canvas;

  /// Canvas visible before this frame is drawn.
  final Uint8List stateBefore;

  /// Rectangle written for this frame, possibly enlarged by the next one.
  _GifRectangle area;

  /// Presentation delay in hundredths of a second.
  final int delayCentiseconds;

  /// Whether [area] is cleared to transparency after presentation.
  bool restoreToBackground = false;

  /// Creates one pending frame.
  _PendingGifFrame({
    required this.canvas,
    required this.stateBefore,
    required this.area,
    required this.delayCentiseconds,
  });
}

/// Pixel rectangle inside the animation canvas.
final class _GifRectangle {
  /// Left edge in pixels.
  final int left;

  /// Top edge in pixels.
  final int top;

  /// Horizontal extent in pixels.
  final int width;

  /// Vertical extent in pixels.
  final int height;

  /// Creates a rectangle from its left, top, width and height.
  const _GifRectangle(this.left, this.top, this.width, this.height);

  /// Smallest rectangle containing this one and [other].
  _GifRectangle union(_GifRectangle other) {
    final int unionLeft = math.min(left, other.left);
    final int unionTop = math.min(top, other.top);
    return _GifRectangle(
      unionLeft,
      unionTop,
      math.max(left + width, other.left + other.width) - unionLeft,
      math.max(top + height, other.top + other.height) - unionTop,
    );
  }
}

/// Accumulates the bounds of individual pixels.
final class _GifBoundsBuilder {
  /// Smallest included column.
  int _left = 0x7fffffff;

  /// Smallest included row.
  int _top = 0x7fffffff;

  /// Largest included column.
  int _right = -1;

  /// Largest included row.
  int _bottom = -1;

  /// Extends the bounds to include the pixel at [x], [y].
  void include(int x, int y) {
    if (x < _left) {
      _left = x;
    }
    if (x > _right) {
      _right = x;
    }
    if (y < _top) {
      _top = y;
    }
    if (y > _bottom) {
      _bottom = y;
    }
  }

  /// Returns the accumulated rectangle, or `null` when nothing was included.
  _GifRectangle? build() => _right < 0 ? null : _GifRectangle(_left, _top, _right - _left + 1, _bottom - _top + 1);
}

/// Clears rectangles of straight-alpha canvases.
extension on Uint8List {
  /// Restores [area] of a canvas [canvasWidth] pixels wide to transparency.
  void fillArea(_GifRectangle area, int canvasWidth) {
    for (int y = area.top; y < area.top + area.height; y++) {
      final int start = (y * canvasWidth + area.left) * 4;
      fillRange(start, start + area.width * 4, 0);
    }
  }
}

/// Quantizes a Dart duration to the nearest representable GIF centisecond.
int _durationCentiseconds(Duration duration) {
  if (duration.isNegative) {
    throw ArgumentError.value(duration, 'duration', 'Frame duration must not be negative');
  }
  final int centiseconds = (duration.inMicroseconds + 5000) ~/ 10000;
  if (centiseconds > 0xffff) {
    throw AnimationCodecException(
      message: 'GIF frame duration ${duration.inMilliseconds} ms exceeds the 655350 ms format limit',
      failure: AnimationCodecFailure.limitExceeded,
    );
  }
  return centiseconds;
}

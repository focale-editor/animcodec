part of '../container.dart';

/// Encodes APNG progressively or retains bounded compressed WebP chunks.
///
/// RIFF needs the final encoded length in its first header. WebP therefore emits
/// bytes at close; it retains compressed output, never previous raw canvases.
final class ImageAnimationStreamEncoder {
  /// Output container (APNG or WebP).
  final AnimationFormat format;

  /// Complete frame canvas width.
  final int width;

  /// Complete frame canvas height.
  final int height;

  /// Number of input frames required before close.
  final int frameCount;

  /// Repeats after the first pass; null once, zero forever.
  final int? loopCount;

  /// Maximum cumulative encoded container size.
  final int maxOutputBytes;

  /// Pending encoded chunks, drained for APNG.
  final BytesBuilder _output = BytesBuilder(copy: false);

  /// Number of complete frames already encoded.
  int _frames = 0;

  /// Next APNG control/data sequence number.
  int _sequence = 0;

  /// Cumulative output including already drained chunks.
  int _bytes = 0;

  /// Whether finalization has succeeded.
  bool _closed = false;

  /// Declares the sequence dimensions and exact number of frames before input.
  ImageAnimationStreamEncoder({required this.format, required this.width, required this.height, required this.frameCount, this.loopCount, this.maxOutputBytes = defaultMaximumAnimationEncodedBytes}) {
    if (format == AnimationFormat.gif) {
      throw ArgumentError('Use GifAnimationStreamEncoder for GIF');
    }
    if (width < 1 || height < 1 || frameCount < 1 || maxOutputBytes < 1 || loopCount != null && (loopCount! < 0 || loopCount! > 65535)) {
      throw ArgumentError('Invalid animation dimensions or limits');
    }
    if (format == AnimationFormat.webp && (width > 16383 || height > 16383 || loopCount == 65535)) {
      throw ArgumentError('WebP dimensions or repetition count exceed the container limit');
    }
    if (format == AnimationFormat.webp) {
      final Uint8List header = Uint8List(10)..[0] = 0x12;
      _put(header, 4, width - 1, 3, little: true);
      _put(header, 7, height - 1, 3, little: true);
      _append(_riffChunk('VP8X', header));
      final Uint8List control = Uint8List(6);
      _put(control, 4, _plays, 2, little: true);
      _append(_riffChunk('ANIM', control));
      _bytes += 12;
    }
  }

  /// Converts normalized repeats to the container's total-play field.
  int get _plays => loopCount == null
      ? 1
      : loopCount == 0
      ? 0
      : loopCount! + 1;

  /// Adds one full straight-alpha frame using source replacement composition.
  void add(RasterAnimationFrame frame) {
    if (_closed || _frames >= frameCount) {
      throw StateError('The animation encoder no longer accepts frames');
    }
    if (frame.image.width != width || frame.image.height != height) {
      throw ArgumentError('Frame dimensions do not match the animation');
    }
    if (format == AnimationFormat.apng) {
      final Uint8List png = imcodec.encodePng(frame.image);
      if (_frames == 0) {
        _append(Uint8List.fromList(_pngSignature));
        _append(Uint8List.sublistView(png, 8, 33));
        final Uint8List animation = Uint8List(8);
        _put(animation, 0, frameCount, 4);
        _put(animation, 4, _plays, 4);
        _append(_pngChunk('acTL', animation));
      }
      final Uint8List control = Uint8List(26);
      _put(control, 0, _sequence++, 4);
      _put(control, 4, width, 4);
      _put(control, 8, height, 4);
      // Reduce microseconds exactly when possible; use a coarser denominator
      // only for very long delays that cannot fit in two unsigned shorts.
      int numerator = frame.duration.inMicroseconds;
      int denominator = 1000000;
      final int divisor = numerator.gcd(denominator);
      numerator ~/= divisor;
      denominator ~/= divisor;
      if (numerator > 65535 || denominator > 65535) {
        denominator = (65535 * 1000000 ~/ frame.duration.inMicroseconds).clamp(1, 65535);
        numerator = (frame.duration.inMicroseconds * denominator / 1000000).round();
      }
      if (numerator > 65535) {
        throw ArgumentError('APNG frame duration exceeds 65535 seconds');
      }
      _put(control, 20, numerator, 2);
      _put(control, 22, denominator, 2);
      _append(_pngChunk('fcTL', control));
      int offset = 8;
      while (offset < png.length) {
        final int length = _read(png, offset, 4);
        if (_tag(png, offset + 4) == 'IDAT') {
          final Uint8List payload = Uint8List.sublistView(png, offset + 8, offset + 8 + length);
          if (_frames == 0) {
            _append(_pngChunk('IDAT', payload));
          } else {
            final Uint8List data = Uint8List(length + 4);
            _put(data, 0, _sequence++, 4);
            data.setRange(4, data.length, payload);
            _append(_pngChunk('fdAT', data));
          }
        }
        offset += length + 12;
      }
    } else {
      final int milliseconds = frame.duration.inMilliseconds;
      if (milliseconds > 0xffffff) {
        throw ArgumentError('WebP frame duration exceeds 24 bits');
      }
      final Uint8List webp = imcodec.encodeWebP(frame.image);
      final BytesBuilder data = BytesBuilder(copy: false);
      final Uint8List control = Uint8List(16)..[15] = 3;
      _put(control, 6, width - 1, 3, little: true);
      _put(control, 9, height - 1, 3, little: true);
      _put(control, 12, milliseconds, 3, little: true);
      data.add(control);
      int offset = 12;
      while (offset < webp.length) {
        final int length = _read(webp, offset + 4, 4, little: true);
        final String tag = _tag(webp, offset);
        final int next = offset + 8 + length + length % 2;
        if (tag == 'VP8L' || tag == 'VP8 ' || tag == 'ALPH') {
          data.add(Uint8List.sublistView(webp, offset, next));
        }
        offset = next;
      }
      _append(_riffChunk('ANMF', data.takeBytes()));
    }
    _frames++;
  }

  /// Returns APNG chunks; WebP waits for the final RIFF size.
  Uint8List drain() => format == AnimationFormat.webp ? Uint8List(0) : _output.takeBytes();

  /// Completes the container only after the declared number of frames arrived.
  Uint8List close() {
    if (_closed || _frames != frameCount) {
      throw StateError('Animation is closed or incomplete');
    }
    _closed = true;
    if (format == AnimationFormat.webp) {
      return _riff(_output.takeBytes());
    }
    _append(_pngChunk('IEND', Uint8List(0)));
    return _output.takeBytes();
  }

  /// Checks cumulative encoded size before retaining a new chunk.
  void _append(Uint8List chunk) {
    _limit(_bytes + chunk.length > maxOutputBytes, 'Animation output exceeds its byte limit');
    _bytes += chunk.length;
    _output.add(chunk);
  }
}

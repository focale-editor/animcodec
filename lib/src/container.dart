import 'dart:convert';
import 'dart:typed_data';

import 'package:animcodec/src/animation.dart';
import 'package:animcodec/src/exception.dart';
import 'package:animcodec/src/gif.dart';
import 'package:imcodec/imcodec.dart' as imcodec;

part 'container/apng.dart';
part 'container/binary.dart';
part 'container/encoder.dart';
part 'container/webp.dart';

/// Portable animated image containers supported by Animcodec.
enum AnimationFormat {
  /// Palette-indexed GIF animation.
  gif,

  /// Full-alpha PNG animation.
  apng,

  /// Lossless-alpha WebP animation.
  webp,
}

/// Limits shared by all animation container readers.
typedef AnimationDecodeOptions = GifAnimationDecodeOptions;

/// Header information with normalized repeat-after-first semantics.
typedef AnimationInfo = GifAnimationInfo;

/// Identifies an animation-capable container from its signature.
AnimationFormat? animationFormat(Uint8List bytes) {
  if (bytes.length >= 6 && ascii.decode(bytes.sublist(0, 3), allowInvalid: true) == 'GIF') {
    return AnimationFormat.gif;
  }
  if (bytes.length >= 8 && _pngSignature.indexed.every((e) => bytes[e.$1] == e.$2)) {
    return AnimationFormat.apng;
  }
  if (bytes.length >= 12 && _tag(bytes, 0) == 'RIFF' && _tag(bytes, 8) == 'WEBP') {
    return AnimationFormat.webp;
  }
  return null;
}

/// Inspects animation structure before allocating any decoded canvases.
///
/// Static PNG/WebP return null; GIF retains its one-frame inspection behavior.
AnimationInfo? inspectAnimation(Uint8List bytes, {AnimationDecodeOptions options = const AnimationDecodeOptions()}) {
  if (animationFormat(bytes) == AnimationFormat.gif) {
    return inspectGifAnimation(bytes, options: options);
  }
  return _parse(bytes, options)?.info;
}

/// Lazily yields owned composited canvases, retaining only working images.
Iterable<RasterAnimationFrame> decodeAnimationFrames(Uint8List bytes, {AnimationDecodeOptions options = const AnimationDecodeOptions()}) {
  if (animationFormat(bytes) == AnimationFormat.gif) {
    return const GifAnimationDecoder().decodeFrames(bytes, options: options);
  }
  final _Sequence? sequence = _parse(bytes, options);
  if (sequence == null) {
    _invalid('The image has no animation');
  }
  _limit(sequence.info.width * sequence.info.height > options.maxDecodedBytes ~/ 16, 'Animation working canvases exceed the byte limit');
  return _compose(sequence);
}

/// Decodes an animation, admitting retained results before decoding pixels.
RasterAnimation decodeAnimation(Uint8List bytes, {AnimationDecodeOptions options = const AnimationDecodeOptions()}) {
  final AnimationInfo? info = inspectAnimation(bytes, options: options);
  if (info == null) {
    _invalid('The image has no animation');
  }
  _limit(info.width * info.height > options.maxDecodedBytes ~/ (4 * (info.frameCount + 4)), 'Decoded animation exceeds the byte limit');
  return RasterAnimation(
    width: info.width,
    height: info.height,
    loopCount: info.loopCount,
    frames: decodeAnimationFrames(bytes, options: options).toList(),
  );
}

/// Encodes full canvas frames using the requested lossless-alpha container.
Uint8List encodeAnimation(RasterAnimation animation, {required AnimationFormat format, int maxOutputBytes = defaultMaximumAnimationEncodedBytes}) {
  if (format == AnimationFormat.gif) {
    return encodeGifAnimation(animation, options: GifAnimationEncodeOptions(maxOutputBytes: maxOutputBytes));
  }
  final ImageAnimationStreamEncoder encoder = ImageAnimationStreamEncoder(
    format: format,
    width: animation.width,
    height: animation.height,
    frameCount: animation.frames.length,
    loopCount: animation.loopCount,
    maxOutputBytes: maxOutputBytes,
  );
  final BytesBuilder result = BytesBuilder(copy: false);
  for (final RasterAnimationFrame frame in animation.frames) {
    encoder.add(frame);
    result.add(encoder.drain());
  }
  result.add(encoder.close());
  return result.takeBytes();
}

/// One validated compressed rectangle referencing the original input.
final class _Frame {
  /// Validated frame rectangle.
  final AnimationFrameArea area;

  /// Delay before advancing.
  final Duration duration;

  /// Canvas restoration after display.
  final AnimationFrameDisposal disposal;

  /// Whether pixels composite over the previous canvas.
  final bool over;

  /// Compressed pixel views borrowed from the input.
  final List<Uint8List> payload;

  /// Retains compressed frame views without copying input.
  _Frame({required this.area, required this.duration, required this.disposal, required this.over, required this.payload});
}

/// Inspected sequence with no decoded pixel allocations.
final class _Sequence {
  /// Container supplying the compressed frames.
  final AnimationFormat format;

  /// Validated canvas, timing and repetition metadata.
  final AnimationInfo info;

  /// Validated frame controls in display order.
  final List<_Frame> frames;

  /// PNG header and shared ancillary chunks.
  final List<Uint8List> prefix;

  /// RGBA background used by WebP disposal.
  final List<int> background;

  /// Retains inspected metadata without decoded canvas storage.
  _Sequence({required this.format, required this.info, required this.frames, this.prefix = const [], this.background = const [0, 0, 0, 0]});
}

/// Dispatches bounded container parsing without touching pixel codecs.
_Sequence? _parse(Uint8List bytes, AnimationDecodeOptions options) {
  options.validate();
  _limit(bytes.length > options.maxEncodedBytes, 'Encoded animation exceeds the byte limit');
  return switch (animationFormat(bytes)) {
    AnimationFormat.apng => _parsePng(bytes, options),
    AnimationFormat.webp => _parseWebP(bytes, options),
    _ => null,
  };
}

/// Composes source/over rectangles with transparent/background/previous disposal.
Iterable<RasterAnimationFrame> _compose(_Sequence sequence) sync* {
  final int width = sequence.info.width;
  final int height = sequence.info.height;
  Uint8List canvas = Uint8List(width * height * 4);
  void clear(AnimationFrameArea area) {
    for (int y = area.y; y < area.y + area.height; y++) {
      for (int x = area.x; x < area.x + area.width; x++) {
        canvas.setRange((y * width + x) * 4, (y * width + x) * 4 + 4, sequence.background);
      }
    }
  }

  clear(AnimationFrameArea.full(width: width, height: height));
  for (final _Frame frame in sequence.frames) {
    final Uint8List? previous = frame.disposal == AnimationFrameDisposal.previous ? Uint8List.fromList(canvas) : null;
    final BytesBuilder encoded = BytesBuilder(copy: false);
    if (sequence.format == AnimationFormat.apng) {
      encoded.add(_pngSignature);
      final Uint8List header = Uint8List.fromList(sequence.prefix.first);
      _put(header, 0, frame.area.width, 4);
      _put(header, 4, frame.area.height, 4);
      encoded.add(_pngChunk('IHDR', header));
      sequence.prefix.skip(1).forEach(encoded.add);
      for (final Uint8List payload in frame.payload) {
        encoded.add(_pngChunk('IDAT', payload));
      }
      encoded.add(_pngChunk('IEND', Uint8List(0)));
    } else {
      final Uint8List extended = Uint8List(10)..[0] = 0x10;
      _put(extended, 4, frame.area.width - 1, 3, little: true);
      _put(extended, 7, frame.area.height - 1, 3, little: true);
      final BytesBuilder chunks = BytesBuilder(copy: false)..add(_riffChunk('VP8X', extended));
      frame.payload.forEach(chunks.add);
      encoded.add(_riff(chunks.takeBytes()));
    }
    final imcodec.Image image = imcodec.decodeImage(
      encoded.takeBytes(),
      options: sequence.format == AnimationFormat.apng ? imcodec.PngDecodeOptions(maxPixels: width * height) : imcodec.WebPDecodeOptions(maxPixels: width * height),
    );
    if (image.width != frame.area.width || image.height != frame.area.height) {
      _invalid('Frame dimensions differ from its container');
    }
    final Uint8List pixels = image.bytes;
    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        final int source = (y * image.width + x) * 4;
        final int target = ((y + frame.area.y) * width + x + frame.area.x) * 4;
        final int alpha = pixels[source + 3];
        if (!frame.over || alpha == 255) {
          canvas.setRange(target, target + 4, pixels, source);
        } else if (alpha != 0) {
          final int remaining = canvas[target + 3] * (255 - alpha);
          final int combined = alpha * 255 + remaining;
          for (int channel = 0; channel < 3; channel++) {
            canvas[target + channel] = ((pixels[source + channel] * alpha * 255 + canvas[target + channel] * remaining) / combined).round();
          }
          canvas[target + 3] = (combined / 255).round();
        }
      }
    }
    yield RasterAnimationFrame(
      image: imcodec.Image.fromRgba(width: width, height: height, bytes: Uint8List.fromList(canvas), copy: false),
      duration: frame.duration,
      sourceArea: frame.area,
      disposal: frame.disposal,
    );
    switch (frame.disposal) {
      case AnimationFrameDisposal.keep:
        break;
      case AnimationFrameDisposal.background:
        clear(frame.area);
      case AnimationFrameDisposal.previous:
        canvas = previous!;
    }
  }
}

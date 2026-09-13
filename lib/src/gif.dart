import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:animcodec/src/animation.dart';
import 'package:animcodec/src/exception.dart';
import 'package:imcodec/imcodec.dart' as imcodec;

part 'gif/decoder.dart';
part 'gif/encoder.dart';
part 'gif/parser.dart';

/// Default maximum encoded GIF size accepted by Animcodec.
const int defaultMaximumAnimationEncodedBytes = 512 * 1024 * 1024;

/// Default aggregate byte budget for decoded frames and working canvases.
const int defaultMaximumAnimationDecodedBytes = 512 * 1024 * 1024;

/// Header-only information about a GIF sequence.
final class GifAnimationInfo {
  /// Logical canvas width.
  final int width;

  /// Logical canvas height.
  final int height;

  /// Number of image descriptors in the file.
  final int frameCount;

  /// Encoded loop value: `null` means absent and zero means forever.
  final int? loopCount;

  /// Sum of all encoded frame delays.
  final Duration duration;

  /// Whether the data stopped before its trailer.
  ///
  /// [frameCount] then counts only the complete frames that were found, which
  /// is what decoding returns. Callers may use this to warn that a file was cut
  /// short while still opening what it contains.
  final bool isTruncated;

  /// Creates inspected GIF animation information.
  const GifAnimationInfo({
    required this.width,
    required this.height,
    required this.frameCount,
    required this.loopCount,
    required this.duration,
    this.isTruncated = false,
  });

  /// Whether the GIF contains more than one image descriptor.
  bool get isAnimated => frameCount > 1;
}

/// Resource limits applied before GIF frames are retained.
final class GifAnimationDecodeOptions {
  /// Largest encoded byte buffer accepted.
  final int maxEncodedBytes;

  /// Largest logical canvas allocation accepted.
  final int maxCanvasPixels;

  /// Largest number of image descriptors accepted.
  final int maxFrames;

  /// Largest aggregate decoded and working allocation accepted.
  final int maxDecodedBytes;

  /// Creates bounded GIF decoding settings.
  const GifAnimationDecodeOptions({
    this.maxEncodedBytes = defaultMaximumAnimationEncodedBytes,
    this.maxCanvasPixels = imcodec.RasterDecodeOptions.defaultMaxPixels,
    this.maxFrames = 1000,
    this.maxDecodedBytes = defaultMaximumAnimationDecodedBytes,
  });

  /// Validates configured limits even when assertions are disabled.
  void validate() {
    if (maxEncodedBytes < 1) {
      throw RangeError.range(maxEncodedBytes, 1, null, 'maxEncodedBytes');
    }
    if (maxCanvasPixels < 1) {
      throw RangeError.range(maxCanvasPixels, 1, null, 'maxCanvasPixels');
    }
    if (maxFrames < 1) {
      throw RangeError.range(maxFrames, 1, null, 'maxFrames');
    }
    if (maxDecodedBytes < 1) {
      throw RangeError.range(maxDecodedBytes, 1, null, 'maxDecodedBytes');
    }
  }
}

/// Settings used to quantize and bound an encoded GIF sequence.
final class GifAnimationEncodeOptions {
  /// Per-frame indexed-colour settings delegated to Imcodec.
  final imcodec.GifEncodeOptions frameOptions;

  /// Largest complete encoded output accepted.
  final int maxOutputBytes;

  /// Creates GIF animation encoding settings.
  const GifAnimationEncodeOptions({
    this.frameOptions = const imcodec.GifEncodeOptions(),
    this.maxOutputBytes = defaultMaximumAnimationEncodedBytes,
  });

  /// Validates configured limits even when assertions are disabled.
  void validate() {
    frameOptions.validate();
    if (maxOutputBytes < 1) {
      throw RangeError.range(maxOutputBytes, 1, null, 'maxOutputBytes');
    }
  }
}

/// Inspects GIF dimensions, timing and frame count without decoding pixels.
GifAnimationInfo inspectGifAnimation(
  Uint8List bytes, {
  GifAnimationDecodeOptions options = const GifAnimationDecodeOptions(),
}) => const GifAnimationDecoder().inspect(bytes, options: options);

/// Decodes every GIF image descriptor to a complete composited RGBA canvas.
RasterAnimation decodeGifAnimation(
  Uint8List bytes, {
  GifAnimationDecodeOptions options = const GifAnimationDecodeOptions(),
}) => const GifAnimationDecoder().decode(bytes, options: options);

/// Encodes complete RGBA canvas frames as a GIF89a animation.
Uint8List encodeGifAnimation(
  RasterAnimation animation, {
  GifAnimationEncodeOptions options = const GifAnimationEncodeOptions(),
}) => const GifAnimationEncoder().encode(animation, options: options);

/// Decodes and inspects bounded GIF animation data.
final class GifAnimationDecoder extends Converter<List<int>, RasterAnimation> {
  /// Default settings used by [convert].
  final GifAnimationDecodeOptions options;

  /// Creates a reusable GIF animation decoder.
  const GifAnimationDecoder({
    this.options = const GifAnimationDecodeOptions(),
  });

  @override
  RasterAnimation convert(List<int> input) => decode(
    input is Uint8List ? input : Uint8List.fromList(input),
    options: options,
  );

  /// Reads header information without allocating frame pixels.
  GifAnimationInfo inspect(
    Uint8List bytes, {
    GifAnimationDecodeOptions? options,
  }) => _inspectGif(bytes, options ?? this.options);

  /// Decodes a complete composited frame sequence.
  RasterAnimation decode(
    Uint8List bytes, {
    GifAnimationDecodeOptions? options,
  }) => _decodeGif(bytes, options ?? this.options);
}

/// Encodes complete RGBA frames as GIF89a data.
final class GifAnimationEncoder extends Converter<RasterAnimation, List<int>> {
  /// Default settings used by [convert].
  final GifAnimationEncodeOptions options;

  /// Creates a reusable GIF animation encoder.
  const GifAnimationEncoder({
    this.options = const GifAnimationEncodeOptions(),
  });

  @override
  Uint8List convert(RasterAnimation input) => encode(input, options: options);

  /// Encodes [animation] with per-operation settings.
  Uint8List encode(
    RasterAnimation animation, {
    GifAnimationEncodeOptions? options,
  }) => _encodeGif(animation, options ?? this.options);
}

/// Reusable `dart:convert` codec for GIF animation sequences.
final class GifAnimationCodec extends Codec<RasterAnimation, List<int>> {
  @override
  final GifAnimationEncoder encoder;

  @override
  final GifAnimationDecoder decoder;

  /// Creates a GIF animation codec with immutable default options.
  const GifAnimationCodec({
    this.encoder = const GifAnimationEncoder(),
    this.decoder = const GifAnimationDecoder(),
  });
}

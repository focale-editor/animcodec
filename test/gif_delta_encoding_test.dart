import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:animcodec/animcodec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart' as imcodec;

/// Exact quantization, so decoded pixels can be compared with their source.
const GifAnimationEncodeOptions _exact = GifAnimationEncodeOptions(
  frameOptions: imcodec.GifEncodeOptions(ditherAmount: 0),
);

/// Checks that changed-rectangle encoding reproduces every source frame.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('changed-rectangle GIF encoding', () {
    test('a moving sprite reproduces every frame in a fraction of the size', () async {
      const int width = 160;
      const int height = 90;
      final List<Uint8List> frames = [
        for (int index = 0; index < 12; index++) _drawSprite(_gradient(width, height), width, height, left: index * 12, top: 40),
      ];

      final Uint8List encoded = encodeGifAnimation(_animation(width, height, frames), options: _exact);

      await _expectFrames(encoded, frames, width, height);
      int fullCanvas = 0;
      for (final Uint8List frame in frames) {
        fullCanvas += imcodec
            .encodeGif(
              imcodec.Image.fromRgba(width: width, height: height, bytes: frame),
              options: _exact.frameOptions,
            )
            .length;
      }
      expect(encoded.length, lessThan(fullCanvas ~/ 3));
    });

    // Flutter's multi-frame codec only caches frames that keep their pixels, so
    // it cannot decode a partial frame drawn after a "restore to background"
    // one (the full-canvas frames of earlier Animcodec versions failed there
    // too). That disposal is the only way to make pixels transparent again, so
    // these sequences are checked against Animcodec's decoder, which the
    // conformance corpus verifies against Skia's own disposal handling.
    test('pixels that become transparent are cleared, including far from the last change', () async {
      const int width = 40;
      const int height = 30;
      final Uint8List opaque = _filled(width, height, 0xff00ff00);
      final Uint8List hole = _filled(width, height, 0xff00ff00);
      for (int y = 2; y < 6; y++) {
        for (int x = 30; x < 38; x++) {
          hole.fillRange((y * width + x) * 4, (y * width + x + 1) * 4, 0);
        }
      }
      final Uint8List sprite = _sprite(width, height, left: 4, top: 20, background: 0);
      final List<Uint8List> frames = [opaque, _copyWithPixel(opaque, width, 1, 1, 0xffff0000), hole, sprite, sprite, opaque, _filled(width, height, 0)];

      final Uint8List encoded = encodeGifAnimation(_animation(width, height, frames), options: _exact);

      await _expectFrames(encoded, frames, width, height, flutter: false);
    });

    for (final bool transparent in [false, true]) {
      test('random edits round-trip exactly${transparent ? ' with appearing and vanishing transparency' : ' through Animcodec and Skia'}', () async {
        const int width = 33;
        const int height = 21;
        final math.Random random = math.Random(transparent ? 7 : 11);
        final List<int> colours = [if (transparent) 0x00000000, 0xffff0000, 0xff00ff00, 0xff0000ff, 0xffffffff, 0xff808080];
        Uint8List current = _filled(width, height, transparent ? 0 : 0xff000000);
        final List<Uint8List> frames = [];
        for (int index = 0; index < 40; index++) {
          current = Uint8List.fromList(current);
          final int edits = random.nextInt(4);
          for (int edit = 0; edit < edits; edit++) {
            final int left = random.nextInt(width);
            final int top = random.nextInt(height);
            final int right = math.min(width, left + 1 + random.nextInt(12));
            final int bottom = math.min(height, top + 1 + random.nextInt(8));
            final int colour = colours[random.nextInt(colours.length)];
            for (int y = top; y < bottom; y++) {
              for (int x = left; x < right; x++) {
                _setPixel(current, width, x, y, colour);
              }
            }
          }
          frames.add(current);
        }

        final Uint8List encoded = encodeGifAnimation(_animation(width, height, frames), options: _exact);

        await _expectFrames(encoded, frames, width, height, flutter: !transparent);
      });
    }

    test('the stream encoder writes the same bytes as whole-sequence encoding', () {
      const int width = 20;
      const int height = 10;
      final List<Uint8List> frames = [for (int index = 0; index < 5; index++) _sprite(width, height, left: index * 3, top: 2, background: 0)];
      final RasterAnimation animation = _animation(width, height, frames);
      final GifAnimationStreamEncoder stream = GifAnimationStreamEncoder(width: width, height: height, loopCount: 0, options: _exact);
      animation.frames.forEach(stream.add);

      expect(stream.close(), encodeGifAnimation(animation, options: _exact));
      expect(() => stream.add(animation.frames.first), throwsStateError);
    });

    test('opaque output without a transparent palette entry still matches', () async {
      const int width = 24;
      const int height = 12;
      final List<Uint8List> frames = [for (int index = 0; index < 6; index++) _sprite(width, height, left: index * 3, top: 1, background: 0xff102030)];
      const GifAnimationEncodeOptions opaque = GifAnimationEncodeOptions(frameOptions: imcodec.GifEncodeOptions(ditherAmount: 0, transparency: false));

      final Uint8List encoded = encodeGifAnimation(_animation(width, height, frames), options: opaque);

      await _expectFrames(encoded, frames, width, height);
    });
  });
}

/// Builds a 0.1 s looping animation from straight RGBA canvases.
RasterAnimation _animation(int width, int height, List<Uint8List> frames) => RasterAnimation(
  width: width,
  height: height,
  loopCount: 0,
  frames: [
    for (final Uint8List frame in frames)
      RasterAnimationFrame(
        image: imcodec.Image.fromRgba(width: width, height: height, bytes: frame),
        duration: const Duration(milliseconds: 100),
      ),
  ],
);

/// Checks decoded frames from Animcodec, and from Skia when [flutter] is set.
Future<void> _expectFrames(Uint8List encoded, List<Uint8List> expected, int width, int height, {bool flutter = true}) async {
  final GifAnimationInfo information = inspectGifAnimation(encoded);
  expect(information.isTruncated, isFalse);
  expect(information.frameCount, expected.length);
  final RasterAnimation decoded = decodeGifAnimation(encoded);
  expect(decoded.frames, hasLength(expected.length));
  for (int index = 0; index < expected.length; index++) {
    expect(decoded.frames[index].image.bytes, expected[index], reason: 'Animcodec frame $index');
  }
  if (!flutter) {
    return;
  }
  final ui.Codec codec = await ui.instantiateImageCodec(encoded);
  addTearDown(codec.dispose);
  expect(codec.frameCount, expected.length);
  for (int index = 0; index < expected.length; index++) {
    final ui.FrameInfo frame = await codec.getNextFrame();
    final ByteData? bytes = await frame.image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    frame.image.dispose();
    expect(bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes), expected[index], reason: 'Skia frame $index');
  }
}

/// Returns a canvas filled with one packed ARGB colour.
Uint8List _filled(int width, int height, int colour) {
  final Uint8List canvas = Uint8List(width * height * 4);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      _setPixel(canvas, width, x, y, colour);
    }
  }
  return canvas;
}

/// Returns a copy of [canvas] with one pixel replaced.
Uint8List _copyWithPixel(Uint8List canvas, int width, int x, int y, int colour) => Uint8List.fromList(canvas)..let((copy) => _setPixel(copy, width, x, y, colour));

/// Returns an opaque stepped colour ramp that still fits one GIF palette.
Uint8List _gradient(int width, int height) {
  final Uint8List canvas = Uint8List(width * height * 4);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      _setPixel(canvas, width, x, y, 0xff000080 | (x * 10 ~/ width * 25) << 16 | (y * 5 ~/ height * 50) << 8);
    }
  }
  return canvas;
}

/// Draws an 8 by 8 red and yellow square over a uniform background.
Uint8List _sprite(int width, int height, {required int left, required int top, required int background}) => _drawSprite(_filled(width, height, background), width, height, left: left, top: top);

/// Draws an 8 by 8 red and yellow square onto [canvas].
Uint8List _drawSprite(Uint8List canvas, int width, int height, {required int left, required int top}) {
  for (int y = top; y < math.min(height, top + 8); y++) {
    for (int x = left; x < math.min(width, left + 8); x++) {
      _setPixel(canvas, width, x, y, (x + y).isEven ? 0xffff0000 : 0xffffff00);
    }
  }
  return canvas;
}

/// Writes a packed ARGB colour as straight RGBA, keeping transparency canonical.
void _setPixel(Uint8List canvas, int width, int x, int y, int colour) {
  final int offset = (y * width + x) * 4;
  final int alpha = colour >>> 24;
  canvas
    ..[offset] = alpha == 0 ? 0 : (colour >> 16) & 0xff
    ..[offset + 1] = alpha == 0 ? 0 : (colour >> 8) & 0xff
    ..[offset + 2] = alpha == 0 ? 0 : colour & 0xff
    ..[offset + 3] = alpha;
}

/// Applies a side effect and returns the receiver.
extension _Let<T> on T {
  /// Calls [action] with this value and returns it.
  T let(void Function(T value) action) {
    action(this);
    return this;
  }
}

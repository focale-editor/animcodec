import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:animcodec/animcodec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart' as imcodec;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('drained chunks match eager output, including transparent disposal', () async {
    final RasterAnimation animation = _animation();
    final GifAnimationStreamEncoder encoder = GifAnimationStreamEncoder(width: 2, height: 1, loopCount: 0);
    final BytesBuilder chunks = BytesBuilder(copy: false)..add(encoder.drain());
    for (final RasterAnimationFrame frame in animation.frames) {
      encoder.add(frame);
      chunks.add(encoder.drain());
      expect(encoder.drain(), isEmpty);
    }
    chunks.add(encoder.close());
    final Uint8List encoded = chunks.takeBytes();
    expect(encoded, encodeGifAnimation(animation));
    final ui.Codec codec = await ui.instantiateImageCodec(encoded);
    addTearDown(codec.dispose);
    for (final RasterAnimationFrame expected in animation.frames) {
      final ui.FrameInfo actual = await codec.getNextFrame();
      final ByteData data = (await actual.image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
      actual.image.dispose();
      expect(data.buffer.asUint8List(), expected.image.bytes);
    }
  });

  test('draining cannot bypass the cumulative encoded size limit', () {
    final RasterAnimation animation = _animation();
    final int length = encodeGifAnimation(animation).length;
    final GifAnimationStreamEncoder encoder = GifAnimationStreamEncoder(width: 2, height: 1, loopCount: 0, options: GifAnimationEncodeOptions(maxOutputBytes: length - 1));
    encoder.drain();
    for (final RasterAnimationFrame frame in animation.frames) {
      encoder.add(frame);
      encoder.drain();
    }
    expect(encoder.close, throwsA(isA<AnimationCodecException>()));
  });

  test('lazy decoding holds a bounded canvas window and leaves yielded frames independent', () {
    final RasterAnimation animation = _animation();
    final Uint8List encoded = encodeGifAnimation(animation);
    const GifAnimationDecodeOptions options = GifAnimationDecodeOptions(maxDecodedBytes: 2 * 1 * 4 * 4);
    final Iterable<RasterAnimationFrame> frames = const GifAnimationDecoder().decodeFrames(encoded, options: options);
    final Iterator<RasterAnimationFrame> iterator = frames.iterator;
    expect(iterator.moveNext(), isTrue);
    final Uint8List first = iterator.current.image.bytes;
    final Uint8List expected = Uint8List.fromList(first);
    int count = 1;
    while (iterator.moveNext()) {
      expect(iterator.current.image.bytes, animation.frames[count].image.bytes);
      count++;
    }
    expect(first, expected);
    expect(count, animation.frames.length);
    expect(() => decodeGifAnimation(encoded, options: options), throwsA(isA<AnimationCodecException>()));
  });
}

/// Exercises repeated content, disappearing pixels and loop-boundary disposal.
RasterAnimation _animation() => RasterAnimation(
  width: 2,
  height: 1,
  loopCount: 0,
  frames: [
    for (final List<int> pixels in [
      [255, 0, 0, 255, 0, 0, 0, 0],
      [255, 0, 0, 255, 0, 255, 0, 255],
      [0, 0, 0, 0, 0, 255, 0, 255],
      [0, 0, 0, 0, 0, 255, 0, 255],
    ])
      RasterAnimationFrame(
        image: imcodec.Image.fromRgba(width: 2, height: 1, bytes: Uint8List.fromList(pixels)),
        duration: const Duration(milliseconds: 80),
      ),
  ],
);

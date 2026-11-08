import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:animcodec/animcodec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart' as imcodec;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final Map<String, Object?> expected = (jsonDecode(File('test/fixtures/alpha_animation/expected.json').readAsStringSync()) as Map).cast<String, Object?>();
  for (final String filename in ['alpha.apng', 'alpha.webp', 'poster.apng', 'lossy.webp']) {
    test('Independent composition agrees for $filename', () {
      final Uint8List bytes = File('test/fixtures/alpha_animation/$filename').readAsBytesSync();
      final RasterAnimation animation = decodeAnimation(bytes);
      expect(animation.frames.length, 4);
      expect(animation.loopCount, filename == 'poster.apng' ? null : 2);
      final List<Object?> pixels = filename.endsWith('.apng')
          ? ((jsonDecode(File('test/fixtures/alpha_animation/chromium.json').readAsStringSync()) as Map)[filename] as List).cast<Object?>()
          : ((expected[filename] as Map)['pixels'] as List).cast<Object?>();
      for (int index = 0; index < 4; index++) {
        final Uint8List actual = animation.frames[index].image.bytes;
        final List<int> oracle = (pixels[index] as List).cast<int>();
        for (int pixel = 0; pixel < actual.length; pixel += 4) {
          expect(actual[pixel + 3], oracle[pixel + 3], reason: '$filename frame $index alpha $pixel');
          if (actual[pixel + 3] != 0) {
            for (int channel = 0; channel < 3; channel++) {
              expect(
                (actual[pixel + channel] - oracle[pixel + channel]).abs(),
                lessThanOrEqualTo(filename == 'lossy.webp' ? 3 : 1),
                reason: '$filename frame $index pixel $pixel channel $channel',
              );
            }
          }
        }
      }
    });
    test('inspection rejects truncated and bounded $filename before decode', () {
      final Uint8List bytes = File('test/fixtures/alpha_animation/$filename').readAsBytesSync();
      for (final AnimationDecodeOptions options in [const AnimationDecodeOptions(maxFrames: 2), const AnimationDecodeOptions(maxCanvasPixels: 4), const AnimationDecodeOptions(maxEncodedBytes: 20)]) {
        expect(() => inspectAnimation(bytes, options: options), throwsA(isA<AnimationCodecException>().having((e) => e.failure, 'failure', AnimationCodecFailure.limitExceeded)));
      }
      expect(() => inspectAnimation(Uint8List.sublistView(bytes, 0, bytes.length - 3)), throwsA(isA<AnimationCodecException>()));
      expect(() => decodeAnimation(bytes, options: const AnimationDecodeOptions(maxDecodedBytes: 10)), throwsA(isA<AnimationCodecException>()));
    });
  }
  test('APNG preserves representable sub-millisecond and long rational delays', () {
    final RasterAnimation input = RasterAnimation(
      width: 1,
      height: 1,
      frames: [
        for (final Duration duration in [const Duration(microseconds: 500), const Duration(seconds: 65535)]) RasterAnimationFrame(image: imcodec.Image(width: 1, height: 1), duration: duration),
      ],
    );
    final RasterAnimation restored = decodeAnimation(encodeAnimation(input, format: AnimationFormat.apng));
    expect(restored.frames.map((frame) => frame.duration), input.frames.map((frame) => frame.duration));
  });
  for (final AnimationFormat format in [AnimationFormat.apng, AnimationFormat.webp]) {
    for (final int? loops in [null, 0, 2]) {
      test('$format output reopens in Skia with alpha timing and loops $loops', () async {
        final List<RasterAnimationFrame> frames = [
          for (final int alpha in [128, 255, 0])
            RasterAnimationFrame(
              image: imcodec.Image.fromRgba(width: 2, height: 2, bytes: Uint8List.fromList([255, 0, 0, alpha, 0, 0, 255, alpha, 255, 0, 0, alpha, 0, 0, 255, alpha])),
              duration: const Duration(milliseconds: 90),
            ),
        ];
        final Uint8List encoded = encodeAnimation(
          RasterAnimation(width: 2, height: 2, frames: frames, loopCount: loops),
          format: format,
        );
        expect(decodeAnimation(encoded).loopCount, loops);
        final ui.Codec codec = await ui.instantiateImageCodec(encoded);
        try {
          expect(codec.frameCount, 3);
          expect(
            codec.repetitionCount,
            loops == null
                ? 0
                : loops == 0
                ? -1
                : loops,
          );
          for (final int alpha in [128, 255, 0]) {
            final ui.FrameInfo frame = await codec.getNextFrame();
            try {
              expect(frame.duration.inMilliseconds, 90);
              expect((await frame.image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.getUint8(3), alpha);
            } finally {
              frame.image.dispose();
            }
          }
        } finally {
          codec.dispose();
        }
      });
    }
    test('$format output budget, frame count, streaming and static detection', () {
      final imcodec.Image image = imcodec.Image.fromRgba(width: 2, height: 1, bytes: Uint8List(8));
      final RasterAnimationFrame frame = RasterAnimationFrame(image: image, duration: const Duration(milliseconds: 40));
      final ImageAnimationStreamEncoder encoder = ImageAnimationStreamEncoder(format: format, width: 2, height: 1, frameCount: 2);
      encoder.add(frame);
      final Uint8List first = encoder.drain();
      expect(first.isEmpty, format == AnimationFormat.webp);
      expect(encoder.close, throwsStateError);
      encoder.add(frame);
      final Uint8List bytes = Uint8List.fromList([...first, ...encoder.drain(), ...encoder.close()]);
      expect(inspectAnimation(bytes)!.frameCount, 2);
      expect(() => encoder.add(frame), throwsStateError);
      expect(() => encodeAnimation(RasterAnimation(width: 2, height: 1, frames: [frame]), format: format, maxOutputBytes: 80), throwsA(isA<AnimationCodecException>()));
      expect(inspectAnimation(format == AnimationFormat.apng ? imcodec.encodePng(image) : imcodec.encodeWebP(image)), isNull);
    });
  }
}

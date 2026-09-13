import 'dart:typed_data';

import 'package:animcodec/animcodec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart' as imcodec;

/// Exercises the public GIF animation codec contract.
void main() {
  group('GIF animation codec', () {
    test('round-trips frame pixels, timing and infinite looping', () {
      final imcodec.Image first = imcodec.Image(width: 2, height: 1)..setPixelRgba(0, 0, 255, 0, 0, 255);
      final imcodec.Image second = imcodec.Image(width: 2, height: 1)..setPixelRgba(1, 0, 0, 255, 0, 255);
      final RasterAnimation source = RasterAnimation(
        width: 2,
        height: 1,
        loopCount: 0,
        frames: [
          RasterAnimationFrame(
            image: first,
            duration: const Duration(milliseconds: 120),
          ),
          RasterAnimationFrame(
            image: second,
            duration: const Duration(milliseconds: 230),
          ),
        ],
      );

      final Uint8List bytes = encodeGifAnimation(
        source,
        options: const GifAnimationEncodeOptions(
          frameOptions: imcodec.GifEncodeOptions(ditherAmount: 0),
        ),
      );
      final GifAnimationInfo information = inspectGifAnimation(bytes);
      final RasterAnimation decoded = decodeGifAnimation(bytes);

      expect(information.width, 2);
      expect(information.height, 1);
      expect(information.frameCount, 2);
      expect(information.loopCount, 0);
      expect(information.duration, const Duration(milliseconds: 350));
      expect(decoded.loopCount, 0);
      expect(decoded.frames[0].duration, const Duration(milliseconds: 120));
      expect(decoded.frames[1].duration, const Duration(milliseconds: 230));
      expect(decoded.frames[0].image.bytes, <int>[255, 0, 0, 255, 0, 0, 0, 0]);
      expect(decoded.frames[1].image.bytes, <int>[0, 0, 0, 0, 0, 255, 0, 255]);
    });

    test('retains an absent loop extension for a still GIF', () {
      final RasterAnimation source = RasterAnimation(
        width: 1,
        height: 1,
        frames: [
          RasterAnimationFrame(
            image: imcodec.Image(width: 1, height: 1)..setPixelRgb(0, 0, 20, 40, 60),
            duration: Duration.zero,
          ),
        ],
      );

      final Uint8List bytes = encodeGifAnimation(source);
      final RasterAnimation decoded = decodeGifAnimation(bytes);

      expect(decoded.loopCount, isNull);
      expect(decoded.frames, hasLength(1));
      expect(decoded.frames.single.image.bytes, <int>[20, 40, 60, 255]);
    });

    test('rejects aggregate decoded allocations before inflating frames', () {
      final RasterAnimation source = RasterAnimation(
        width: 2,
        height: 2,
        loopCount: 0,
        frames: [
          RasterAnimationFrame(
            image: imcodec.Image(width: 2, height: 2),
            duration: const Duration(milliseconds: 100),
          ),
          RasterAnimationFrame(
            image: imcodec.Image(width: 2, height: 2),
            duration: const Duration(milliseconds: 100),
          ),
        ],
      );
      final Uint8List bytes = encodeGifAnimation(source);

      expect(
        () => decodeGifAnimation(
          bytes,
          options: const GifAnimationDecodeOptions(maxDecodedBytes: 63),
        ),
        throwsA(isA<AnimationCodecException>().having((error) => error.failure, 'failure', AnimationCodecFailure.limitExceeded)),
      );
    });

    test('keeps complete frames of a cut file and rejects excessive frame counts', () {
      final RasterAnimation source = RasterAnimation(
        width: 1,
        height: 1,
        loopCount: 0,
        frames: [
          RasterAnimationFrame(
            image: imcodec.Image(width: 1, height: 1)..setPixelRgb(0, 0, 255, 0, 0),
            duration: const Duration(milliseconds: 100),
          ),
          RasterAnimationFrame(
            image: imcodec.Image(width: 1, height: 1)..setPixelRgb(0, 0, 0, 0, 255),
            duration: const Duration(milliseconds: 100),
          ),
        ],
      );
      final Uint8List bytes = encodeGifAnimation(source);

      final Uint8List withoutTrailer = Uint8List.sublistView(bytes, 0, bytes.length - 1);
      final GifAnimationInfo cut = inspectGifAnimation(withoutTrailer);
      expect(cut.isTruncated, isTrue);
      expect(cut.frameCount, 2);
      expect(decodeGifAnimation(withoutTrailer).frames, hasLength(2));
      expect(inspectGifAnimation(bytes).isTruncated, isFalse);

      // Cutting inside the second frame keeps the first one.
      final Uint8List insideSecondFrame = Uint8List.sublistView(bytes, 0, bytes.length - 4);
      expect(decodeGifAnimation(insideSecondFrame).frames, hasLength(1));

      // Nothing complete to show: still an error, reported as truncation.
      expect(
        () => inspectGifAnimation(Uint8List.sublistView(bytes, 0, 20)),
        throwsA(isA<AnimationCodecException>().having((error) => error.failure, 'failure', AnimationCodecFailure.truncated)),
      );
      expect(
        () => inspectGifAnimation(
          bytes,
          options: const GifAnimationDecodeOptions(maxFrames: 1),
        ),
        throwsA(isA<AnimationCodecException>().having((error) => error.failure, 'failure', AnimationCodecFailure.limitExceeded)),
      );
    });

    test('rejects invalid frame rectangles before encoding', () {
      expect(
        () => AnimationFrameArea(x: -1, y: 0, width: 1, height: 1),
        throwsArgumentError,
      );
      expect(
        () => RasterAnimation(
          width: 1,
          height: 1,
          frames: [
            RasterAnimationFrame(
              image: imcodec.Image(width: 1, height: 1),
              duration: Duration.zero,
              sourceArea: AnimationFrameArea(
                x: 0,
                y: 0,
                width: 2,
                height: 1,
              ),
            ),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('enforces the configured encoded output limit', () {
      final RasterAnimation source = RasterAnimation(
        width: 1,
        height: 1,
        frames: [
          RasterAnimationFrame(
            image: imcodec.Image(width: 1, height: 1),
            duration: Duration.zero,
          ),
        ],
      );

      expect(
        () => encodeGifAnimation(
          source,
          options: const GifAnimationEncodeOptions(maxOutputBytes: 12),
        ),
        throwsA(isA<AnimationCodecException>()),
      );
    });
  });
}

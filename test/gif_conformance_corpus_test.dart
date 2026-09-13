import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:animcodec/animcodec.dart';
import 'package:flutter_test/flutter_test.dart';

/// Relative directory containing the vendored GIF conformance fixtures.
const String _fixtureRoot = 'test/fixtures/gif_conformance';

/// Invalid fixtures that still hold complete frames, which Skia displays.
const Set<String> _recoverableInvalidFixtures = {'no_trailer.gif'};

/// Checks Animcodec against the independent conformance fixture corpus.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('codec-corpus GIF conformance suite', () {
    final List<File> validFiles = _gifFiles('$_fixtureRoot/valid');

    for (final File file in validFiles) {
      test('${file.uri.pathSegments.last} matches Flutter/Skia', () async {
        final String name = file.uri.pathSegments.last;
        final Uint8List bytes = await file.readAsBytes();
        final GifAnimationInfo information = inspectGifAnimation(bytes);
        final RasterAnimation animation = decodeGifAnimation(bytes);
        final ui.Codec reference = await ui.instantiateImageCodec(bytes);
        addTearDown(reference.dispose);

        expect(information.frameCount, reference.frameCount);
        expect(animation.frames, hasLength(reference.frameCount));
        expect(animation.width, information.width);
        expect(animation.height, information.height);

        for (int index = 0; index < reference.frameCount; index++) {
          final ui.FrameInfo referenceFrame = await reference.getNextFrame();
          final ByteData? referenceBytes = await referenceFrame.image.toByteData(
            format: ui.ImageByteFormat.rawStraightRgba,
          );
          referenceFrame.image.dispose();

          expect(referenceBytes, isNotNull);
          expect(
            animation.frames[index].image.bytes,
            referenceBytes!.buffer.asUint8List(
              referenceBytes.offsetInBytes,
              referenceBytes.lengthInBytes,
            ),
            reason: 'composited pixels of frame $index of $name',
          );
        }
      });
    }

    test('disposes to transparency rather than the logical background colour', () {
      final RasterAnimation none = _decode('dispose_none.gif');
      final RasterAnimation unspecified = _decode('dispose_unspecified.gif');
      final RasterAnimation background = _decode('dispose_background.gif');
      final RasterAnimation previous = _decode('dispose_previous.gif');

      for (final RasterAnimation animation in [none, unspecified]) {
        expect(_pixel(animation, frame: 0, x: 1, y: 1), [255, 0, 0, 255]);
        expect(_pixel(animation, frame: 0, x: 6, y: 1), [0, 0, 0, 0]);
        expect(_pixel(animation, frame: 1, x: 1, y: 1), [255, 0, 0, 255]);
        expect(_pixel(animation, frame: 1, x: 6, y: 1), [0, 0, 255, 255]);
      }
      for (final RasterAnimation animation in [background, previous]) {
        expect(_pixel(animation, frame: 1, x: 1, y: 1), [0, 0, 0, 0]);
        expect(_pixel(animation, frame: 1, x: 6, y: 1), [0, 0, 255, 255]);
      }
    });

    test('composites offset and overlapping frame rectangles', () {
      final RasterAnimation offset = _decode('small_frame_big_canvas.gif');
      expect(_pixel(offset, frame: 0, x: 0, y: 0), [0, 0, 0, 0]);
      expect(_pixel(offset, frame: 0, x: 6, y: 6), [255, 0, 0, 255]);
      expect(_pixel(offset, frame: 0, x: 9, y: 9), [255, 0, 0, 255]);
      expect(_pixel(offset, frame: 0, x: 10, y: 10), [0, 0, 0, 0]);

      final RasterAnimation overlapping = _decode('overlapping_frames.gif');
      expect(_pixel(overlapping, frame: 0, x: 15, y: 15), [0, 0, 0, 0]);
      expect(
        _pixel(overlapping, frame: 1, x: 2, y: 2),
        [255, 0, 0, 255],
      );
      expect(
        _pixel(overlapping, frame: 1, x: 5, y: 5),
        [0, 0, 255, 255],
      );
      expect(_pixel(overlapping, frame: 1, x: 14, y: 14), [0, 0, 0, 0]);
    });

    test('retains timing and loop metadata exactly', () {
      final Map<String, List<Duration>> expectedDurations = {
        'delay_0.gif': [Duration.zero, Duration.zero],
        'delay_10ms.gif': [
          const Duration(milliseconds: 10),
          const Duration(milliseconds: 10),
        ],
        'delay_1s.gif': [
          const Duration(seconds: 1),
          const Duration(seconds: 1),
        ],
        'variable_delay.gif': [
          const Duration(milliseconds: 100),
          const Duration(milliseconds: 500),
          const Duration(seconds: 1),
          const Duration(seconds: 2),
        ],
      };
      for (final MapEntry<String, List<Duration>> entry in expectedDurations.entries) {
        final Uint8List bytes = File(
          '$_fixtureRoot/valid/${entry.key}',
        ).readAsBytesSync();
        final RasterAnimation animation = decodeGifAnimation(bytes);
        expect(
          animation.frames.map((frame) => frame.duration),
          entry.value,
          reason: entry.key,
        );
      }

      expect(_inspect('loop_infinite.gif').loopCount, 0);
      expect(_inspect('loop_once.gif').loopCount, 1);
      expect(_inspect('loop_3.gif').loopCount, 3);
      expect(_inspect('no_loop_ext.gif').loopCount, isNull);
    });

    for (final File file in _gifFiles('$_fixtureRoot/invalid')) {
      final String name = file.uri.pathSegments.last;
      if (_recoverableInvalidFixtures.contains(name)) {
        test('$name keeps its complete frames like Flutter/Skia', () async {
          final Uint8List bytes = file.readAsBytesSync();
          final ui.Codec reference = await ui.instantiateImageCodec(bytes);
          addTearDown(reference.dispose);

          expect(inspectGifAnimation(bytes).isTruncated, isTrue);
          expect(decodeGifAnimation(bytes).frames, hasLength(reference.frameCount));
        });
        continue;
      }
      test('$name is rejected', () {
        final Uint8List bytes = file.readAsBytesSync();
        expect(
          () => decodeGifAnimation(bytes),
          throwsA(isA<AnimationCodecException>()),
        );
      });
    }

    for (final File file in _gifFiles('$_fixtureRoot/edge-cases')) {
      test('${file.uri.pathSegments.last} is accepted', () {
        final Uint8List bytes = file.readAsBytesSync();
        final RasterAnimation animation = decodeGifAnimation(bytes);

        expect(animation.frames, isNotEmpty);
        expect(animation.width, greaterThan(0));
        expect(animation.height, greaterThan(0));
      });
    }
  });
}

/// Returns the sorted GIF files directly contained by [directory].
List<File> _gifFiles(String directory) =>
    Directory(directory).listSync().whereType<File>().where((file) => file.path.endsWith('.gif')).toList()..sort((left, right) => left.path.compareTo(right.path));

/// Inspects the valid corpus fixture identified by [name].
GifAnimationInfo _inspect(String name) => inspectGifAnimation(
  File('$_fixtureRoot/valid/$name').readAsBytesSync(),
);

/// Decodes the valid corpus fixture identified by [name].
RasterAnimation _decode(String name) => decodeGifAnimation(
  File('$_fixtureRoot/valid/$name').readAsBytesSync(),
);

/// Returns one straight-alpha pixel from a decoded animation [frame].
List<int> _pixel(
  RasterAnimation animation, {
  required int frame,
  required int x,
  required int y,
}) {
  final Uint8List bytes = animation.frames[frame].image.bytes;
  final int offset = (y * animation.width + x) * 4;
  return bytes.sublist(offset, offset + 4);
}

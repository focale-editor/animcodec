import 'dart:developer';
import 'dart:typed_data';

import 'package:animcodec/animcodec.dart';
import 'package:imcodec/imcodec.dart' as imcodec;

/// Creates, edits, and encodes a small two-frame GIF animation.
void main() {
  final RasterAnimation animation = RasterAnimation(
    width: 2,
    height: 1,
    loopCount: 0,
    frames: [
      RasterAnimationFrame(
        image: imcodec.Image(width: 2, height: 1)..setPixelRgb(0, 0, 255, 0, 0),
        duration: const Duration(milliseconds: 120),
      ),
      RasterAnimationFrame(
        image: imcodec.Image(width: 2, height: 1)..setPixelRgb(1, 0, 0, 255, 0),
        duration: const Duration(milliseconds: 240),
      ),
    ],
  );

  animation.frames.last.image.setPixelRgb(0, 0, 0, 0, 255);
  final Uint8List encoded = encodeGifAnimation(animation);
  final GifAnimationInfo information = inspectGifAnimation(encoded);

  log(
    'Encoded ${information.frameCount} frames over '
    '${information.duration.inMilliseconds} ms into '
    '${encoded.lengthInBytes} GIF bytes.',
    name: 'animcodec.example',
  );
}

<p align="center">
  <img src="screenshots/overview.png" alt="Animcodec package illustration" width="180">
</p>

# Animcodec

Animcodec decodes and encodes editable raster animation sequences on top of
[Imcodec](https://github.com/focale-editor/imcodec). Its first supported
container is GIF89a, including frame offsets, local and global palettes,
transparency, delays, loop metadata and disposal methods.

Decoded frames are complete straight-alpha RGBA canvases. This deliberately
keeps GIF palette and delta-frame details out of editors: modify, reorder or
replace the frames, then encode the resulting sequence again.

```dart
import 'dart:typed_data';

import 'package:animcodec/animcodec.dart';

final RasterAnimation animation = decodeGifAnimation(bytes);
final RasterAnimation edited = RasterAnimation(
  width: animation.width,
  height: animation.height,
  loopCount: 0,
  frames: animation.frames.reversed.toList(),
);
final Uint8List encoded = encodeGifAnimation(edited);

// Or encode a long sequence without holding every frame in memory.
final GifAnimationStreamEncoder stream = GifAnimationStreamEncoder(
  width: animation.width,
  height: animation.height,
  loopCount: 0,
);
edited.frames.forEach(stream.add);
final Uint8List streamed = stream.close();
```

All inputs are bounded by encoded size, canvas pixels, frame count and aggregate
decoded bytes. An `AnimationCodecException` reports whether the data was
malformed, cut short, or valid but beyond a configured limit. A file that stops
early still yields every complete frame, as in browsers, and
`GifAnimationInfo.isTruncated` tells the caller it happened. Canvases start
transparent and "restore to background" clears to transparency, matching Skia
and browsers rather than the rarely honoured logical-screen colour.

Each frame after the first is encoded as the smallest rectangle holding its
changes, with unchanged pixels inside it left transparent. Frames can be added
one at a time through `GifAnimationStreamEncoder`, which retains only two
canvases whatever the length of the sequence. GIF durations are rounded to the
nearest 10 milliseconds, the smallest interval the container can represent.

Flutter's own multi-frame codec cannot draw a partial frame that follows a
"restore to background" frame. Animcodec only uses that disposal when pixels
must become transparent again, which the format cannot express otherwise.

The test suite includes the public-domain
[imazen GIF conformance corpus](https://github.com/imazen/codec-corpus/tree/main/gif-conformance),
covering valid, malformed and edge-case files. It also checks decoded pixels
against Flutter's independent Skia-backed decoder where both implementations
use the same logical-background convention.

---

Built for **[Focale](https://focale-editor.app)**, an advanced local image editor. Discover what these packages make possible in a real creative workflow.

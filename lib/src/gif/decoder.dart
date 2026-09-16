part of '../gif.dart';

/// Inspects one parsed GIF without allocating decompressed frame canvases.
GifAnimationInfo _inspectGif(
  Uint8List bytes,
  GifAnimationDecodeOptions options,
) {
  final _ParsedGif parsed = _ParsedGif.parse(bytes: bytes, options: options);
  final int totalCentiseconds = parsed.frames.fold(
    0,
    (total, frame) => total + frame.control.delayCentiseconds,
  );
  return GifAnimationInfo(
    width: parsed.width,
    height: parsed.height,
    frameCount: parsed.frames.length,
    loopCount: parsed.loopCount,
    duration: Duration(milliseconds: totalCentiseconds * 10),
    isTruncated: parsed.truncated,
  );
}

/// Decodes and composites all parsed GIF frames in presentation order.
///
/// The canvas starts transparent and "restore to background" clears to
/// transparency. The logical-screen background colour is deliberately ignored,
/// as browsers, Skia and Imcodec's still decoder all do: honouring it would
/// make the first frame of an animated file look different from the same
/// image decoded as a still.
RasterAnimation _decodeGif(
  Uint8List bytes,
  GifAnimationDecodeOptions options,
) {
  final _ParsedGif parsed = _ParsedGif.parse(bytes: bytes, options: options);
  return RasterAnimation(
    width: parsed.width,
    height: parsed.height,
    frames: _decodeGifFrames(parsed, options, retainFrames: true).toList(growable: false),
    loopCount: parsed.loopCount,
  );
}

/// Yields independently owned canvases without retaining earlier results.
Iterable<RasterAnimationFrame> _decodeGifFrames(
  _ParsedGif parsed,
  GifAnimationDecodeOptions options, {
  bool retainFrames = false,
}) sync* {
  final int canvasBytes = parsed.width * parsed.height * 4;
  final Uint8List canvas = Uint8List(canvasBytes);
  int frameCount = 0;
  for (final _ParsedGifFrame frame in parsed.frames) {
    final int retainedAndWorkingBytes = canvasBytes * ((retainFrames ? frameCount : 0) + 4);
    if (retainedAndWorkingBytes > options.maxDecodedBytes) {
      throw AnimationCodecException(
        message: 'GIF frames need at least $retainedAndWorkingBytes decoded bytes, exceeding the ${options.maxDecodedBytes} byte limit',
        failure: AnimationCodecFailure.limitExceeded,
      );
    }
    final Uint8List? previous = frame.control.disposal == AnimationFrameDisposal.previous ? Uint8List.fromList(canvas) : null;
    final imcodec.Image patch;
    try {
      patch = imcodec.decodeGif(
        _buildStaticGif(parsed, frame),
        options: imcodec.GifDecodeOptions(
          maxPixels: options.maxCanvasPixels,
        ),
      );
    } on Object catch (error) {
      // A damaged frame after complete ones ends the sequence, as it does in
      // browsers; a damaged first frame leaves nothing worth showing.
      if (frameCount > 0) {
        break;
      }
      throw AnimationCodecException(
        message: 'Could not decode GIF frame 1',
        cause: error,
      );
    }
    final AnimationFrameArea sourceArea = AnimationFrameArea(
      x: frame.left,
      y: frame.top,
      width: frame.width,
      height: frame.height,
    );
    _compositePatch(
      canvas,
      patch.bytes,
      canvasWidth: parsed.width,
      area: sourceArea,
    );
    yield RasterAnimationFrame(
      image: imcodec.Image.fromRgba(
        width: parsed.width,
        height: parsed.height,
        bytes: Uint8List.fromList(canvas),
        copy: false,
      ),
      duration: Duration(
        milliseconds: frame.control.delayCentiseconds * 10,
      ),
      sourceArea: sourceArea,
      disposal: frame.control.disposal,
    );
    frameCount++;
    switch (frame.control.disposal) {
      case AnimationFrameDisposal.keep:
        break;
      case AnimationFrameDisposal.background:
        _clearArea(
          canvas,
          canvasWidth: parsed.width,
          area: sourceArea,
        );
      case AnimationFrameDisposal.previous:
        canvas.setAll(0, previous!);
    }
  }
}

/// Restores one rectangular canvas area to transparency.
void _clearArea(
  Uint8List canvas, {
  required int canvasWidth,
  required AnimationFrameArea area,
}) {
  for (int y = area.y; y < area.y + area.height; y++) {
    final int start = (y * canvasWidth + area.x) * 4;
    canvas.fillRange(start, start + area.width * 4, 0);
  }
}

/// Draws nontransparent patch pixels over the current canvas.
void _compositePatch(
  Uint8List canvas,
  Uint8List patch, {
  required int canvasWidth,
  required AnimationFrameArea area,
}) {
  for (int y = area.y; y < area.y + area.height; y++) {
    for (int x = area.x; x < area.x + area.width; x++) {
      final int offset = (y * canvasWidth + x) * 4;
      if (patch[offset + 3] != 0) {
        canvas.setRange(offset, offset + 4, patch, offset);
      }
    }
  }
}

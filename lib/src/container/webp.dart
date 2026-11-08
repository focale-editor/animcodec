part of '../container.dart';

/// Parses RIFF animation rectangles and preserves compressed pixel subchunks.
_Sequence? _parseWebP(Uint8List bytes, AnimationDecodeOptions options) {
  if (_read(bytes, 4, 4, little: true) + 8 != bytes.length) {
    _invalid('Invalid WebP RIFF length');
  }
  final List<_Frame> frames = [];
  int width = 0;
  int height = 0;
  int? loops;
  bool animated = false;
  bool control = false;
  List<int> background = [0, 0, 0, 0];
  int offset = 12;
  while (offset < bytes.length) {
    if (offset + 8 > bytes.length) {
      _invalid('Truncated WebP chunk');
    }
    final String tag = _tag(bytes, offset);
    final int length = _read(bytes, offset + 4, 4, little: true);
    final int end = offset + 8 + length;
    if (end + length % 2 > bytes.length) {
      _invalid('Truncated WebP chunk');
    }
    final Uint8List data = Uint8List.sublistView(bytes, offset + 8, end);
    switch (tag) {
      case 'VP8X':
        if (offset != 12 || length != 10) {
          _invalid('Invalid WebP extended header');
        }
        animated = data[0] & 2 != 0;
        width = _read(data, 4, 3, little: true) + 1;
        height = _read(data, 7, 3, little: true) + 1;
        _canvas(width, height, options);
      case 'ANIM':
        if (!animated) {
          break;
        }
        if (control || length != 6 || frames.isNotEmpty) {
          _invalid('Invalid WebP animation control');
        }
        control = true;
        background = [data[2], data[1], data[0], data[3]];
        loops = _repeats(_read(data, 4, 2, little: true));
      case 'ANMF':
        if (!animated) {
          break;
        }
        if (!control || length < 16) {
          _invalid('Missing WebP animation control');
        }
        final int x = _read(data, 0, 3, little: true) * 2;
        final int y = _read(data, 3, 3, little: true) * 2;
        final int w = _read(data, 6, 3, little: true) + 1;
        final int h = _read(data, 9, 3, little: true) + 1;
        if (x + w > width || y + h > height || data[15] & 0xfc != 0) {
          _invalid('Invalid WebP frame rectangle or flags');
        }
        final List<Uint8List> payload = [];
        int cursor = 16;
        int images = 0;
        bool alpha = false;
        while (cursor < data.length) {
          if (cursor + 8 > data.length) {
            _invalid('Truncated WebP pixel chunk');
          }
          final String type = _tag(data, cursor);
          final int size = _read(data, cursor + 4, 4, little: true);
          final int next = cursor + 8 + size + size % 2;
          if (next > data.length) {
            _invalid('Truncated WebP pixel data');
          }
          if (type == 'ALPH') {
            if (alpha || images != 0) {
              _invalid('Invalid WebP alpha order');
            }
            alpha = true;
            payload.add(Uint8List.sublistView(data, cursor, next));
          } else if (type == 'VP8 ' || type == 'VP8L') {
            if (++images != 1 || type == 'VP8L' && alpha) {
              _invalid('Invalid WebP pixel order');
            }
            payload.add(Uint8List.sublistView(data, cursor, next));
          }
          cursor = next;
        }
        if (images != 1) {
          _invalid('Missing WebP frame pixels');
        }
        _limit(frames.length >= options.maxFrames, 'Animation exceeds the frame limit');
        frames.add(
          _Frame(
            area: AnimationFrameArea(x: x, y: y, width: w, height: h),
            duration: Duration(milliseconds: _read(data, 12, 3, little: true)),
            disposal: data[15] & 1 == 0 ? AnimationFrameDisposal.keep : AnimationFrameDisposal.background,
            over: data[15] & 2 == 0,
            payload: payload,
          ),
        );
    }
    offset = end + length % 2;
  }
  if (!animated) {
    return null;
  }
  if (!control || frames.isEmpty) {
    _invalid('Empty WebP animation');
  }
  return _Sequence(
    format: AnimationFormat.webp,
    frames: frames,
    background: background,
    info: AnimationInfo(width: width, height: height, frameCount: frames.length, loopCount: loops, duration: frames.fold(Duration.zero, (sum, frame) => sum + frame.duration)),
  );
}

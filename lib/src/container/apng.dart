part of '../container.dart';

/// Parses APNG controls, including a default PNG excluded from the animation.
_Sequence? _parsePng(Uint8List bytes, AnimationDecodeOptions options) {
  final List<_Frame> frames = [];
  final List<Uint8List> prefix = [];
  int width = 0;
  int height = 0;
  int? declared;
  int? loops;
  int sequence = 0;
  int offset = 8;
  bool dataSeen = false;
  bool ended = false;
  bool defaultFrame = false;
  _Frame? current;
  while (offset < bytes.length) {
    final int length = _read(bytes, offset, 4);
    if (offset + length + 12 > bytes.length) {
      _invalid('Truncated PNG chunk');
    }
    final String tag = _tag(bytes, offset + 4);
    if (_crc(bytes, offset + 4, offset + 8 + length) != _read(bytes, offset + 8 + length, 4)) {
      _invalid('Invalid PNG checksum');
    }
    final Uint8List data = Uint8List.sublistView(bytes, offset + 8, offset + 8 + length);
    if (offset == 8 && tag != 'IHDR') {
      _invalid('PNG must start with IHDR');
    }
    switch (tag) {
      case 'IHDR':
        if (offset != 8 || length != 13) {
          _invalid('Invalid PNG header');
        }
        width = _read(data, 0, 4);
        height = _read(data, 4, 4);
        _canvas(width, height, options);
        prefix.add(data);
      case 'acTL':
        if (declared != null || dataSeen || length != 8) {
          _invalid('Invalid APNG animation control');
        }
        declared = _read(data, 0, 4);
        if (declared == 0) {
          _invalid('Empty APNG sequence');
        }
        _limit(declared > options.maxFrames, 'Animation exceeds the frame limit');
        loops = _repeats(_read(data, 4, 4));
      case 'fcTL':
        if (declared == null || length != 26 || _read(data, 0, 4) != sequence++) {
          _invalid('Invalid APNG frame sequence');
        }
        if (current != null && current.payload.isEmpty) {
          _invalid('APNG frame has no data');
        }
        final int w = _read(data, 4, 4);
        final int h = _read(data, 8, 4);
        final int x = _read(data, 12, 4);
        final int y = _read(data, 16, 4);
        if (w < 1 || h < 1 || x + w > width || y + h > height || data[24] > 2 || data[25] > 1) {
          _invalid('Invalid APNG frame rectangle or operation');
        }
        if (!dataSeen && (w != width || h != height || x != 0 || y != 0)) {
          _invalid('The default APNG frame must cover the canvas');
        }
        defaultFrame = !dataSeen;
        final int denominator = _read(data, 22, 2);
        current = _Frame(
          area: AnimationFrameArea(x: x, y: y, width: w, height: h),
          duration: Duration(microseconds: (_read(data, 20, 2) * 1000000 / (denominator == 0 ? 100 : denominator)).round()),
          disposal: AnimationFrameDisposal.values[data[24]],
          over: data[25] == 1,
          payload: [],
        );
        frames.add(current);
        _limit(frames.length > options.maxFrames, 'Animation exceeds the frame limit');
      case 'IDAT':
        if (current != null && !defaultFrame) {
          _invalid('IDAT belongs to the default PNG only');
        }
        dataSeen = true;
        current?.payload.add(data);
      case 'fdAT':
        if (!dataSeen || current == null || defaultFrame || length < 4 || _read(data, 0, 4) != sequence++) {
          _invalid('Invalid APNG frame payload');
        }
        current.payload.add(Uint8List.sublistView(data, 4));
      case 'IEND':
        if (length != 0 || !dataSeen) {
          _invalid('Invalid PNG end');
        }
        ended = true;
      default:
        if (!dataSeen && tag != 'acTL') {
          prefix.add(Uint8List.sublistView(bytes, offset, offset + length + 12));
        }
    }
    offset += length + 12;
    if (ended) {
      break;
    }
  }
  if (!ended || offset != bytes.length) {
    _invalid('Truncated or trailing PNG data');
  }
  if (declared == null) {
    return null;
  }
  if (frames.length != declared || current == null || current.payload.isEmpty) {
    _invalid('APNG frame count does not match its controls');
  }
  return _Sequence(
    format: AnimationFormat.apng,
    frames: frames,
    prefix: prefix,
    info: AnimationInfo(width: width, height: height, frameCount: frames.length, loopCount: loops, duration: frames.fold(Duration.zero, (sum, frame) => sum + frame.duration)),
  );
}

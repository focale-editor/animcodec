part of '../container.dart';

/// PNG magic bytes.
const List<int> _pngSignature = [137, 80, 78, 71, 13, 10, 26, 10];

/// Throws a container error without exposing range errors to callers.
Never _invalid(String message) => throw AnimationCodecException(message: message);

/// Rejects a resource limit before allocation.
void _limit(bool exceeded, String message) {
  if (exceeded) {
    throw AnimationCodecException(message: message, failure: AnimationCodecFailure.limitExceeded);
  }
}

/// Reads a checked unsigned integer.
int _read(Uint8List bytes, int at, int count, {bool little = false}) {
  if (at < 0 || at + count > bytes.length) {
    _invalid('Truncated animation field');
  }
  int value = 0;
  for (int index = 0; index < count; index++) {
    value = value * 256 + bytes[at + (little ? count - index - 1 : index)];
  }
  return value;
}

/// Writes an unsigned integer.
void _put(Uint8List bytes, int at, int value, int count, {bool little = false}) {
  int remaining = value;
  for (int index = 0; index < count; index++) {
    bytes[at + (little ? index : count - index - 1)] = remaining & 255;
    remaining ~/= 256;
  }
}

/// Reads a container chunk type.
String _tag(Uint8List bytes, int at) => String.fromCharCodes(bytes.sublist(at, at + 4));

/// Computes PNG's IEEE CRC over a checked range.
int _crc(Uint8List bytes, int start, int end) {
  int value = 0xffffffff;
  for (int index = start; index < end; index++) {
    value = _crcTable[(value ^ bytes[index]) & 255] ^ (value >>> 8);
  }
  return (value ^ 0xffffffff) & 0xffffffff;
}

/// CRC table shared by all chunks.
final List<int> _crcTable = List.generate(256, (index) {
  int value = index;
  for (int bit = 0; bit < 8; bit++) {
    value = value & 1 == 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  }
  return value;
});

/// Builds one checksummed PNG chunk.
Uint8List _pngChunk(String tag, Uint8List data) {
  final Uint8List chunk = Uint8List(data.length + 12);
  _put(chunk, 0, data.length, 4);
  chunk.setRange(4, 8, tag.codeUnits);
  chunk.setRange(8, 8 + data.length, data);
  _put(chunk, chunk.length - 4, _crc(chunk, 4, chunk.length - 4), 4);
  return chunk;
}

/// Builds an even-padded RIFF chunk.
Uint8List _riffChunk(String tag, Uint8List data) {
  final Uint8List chunk = Uint8List(8 + data.length + data.length % 2);
  chunk.setRange(0, 4, tag.codeUnits);
  _put(chunk, 4, data.length, 4, little: true);
  chunk.setRange(8, 8 + data.length, data);
  return chunk;
}

/// Wraps WebP chunks with their final RIFF size.
Uint8List _riff(Uint8List chunks) {
  final Uint8List result = Uint8List(12 + chunks.length);
  result.setRange(0, 4, 'RIFF'.codeUnits);
  _put(result, 4, chunks.length + 4, 4, little: true);
  result.setRange(8, 12, 'WEBP'.codeUnits);
  result.setRange(12, result.length, chunks);
  return result;
}

/// Validates a canvas before any frame descriptors or pixel buffers are kept.
void _canvas(int width, int height, AnimationDecodeOptions options) {
  if (width < 1 || height < 1) {
    _invalid('Empty animation canvas');
  }
  _limit(width > options.maxCanvasPixels ~/ height, 'Animation canvas exceeds the pixel limit');
}

/// Normalizes total plays to repeat-after-first, preserving once and forever.
int? _repeats(int plays) {
  _limit(plays > 65536, 'Animation repetition count exceeds the supported limit');
  return plays == 0
      ? 0
      : plays == 1
      ? null
      : plays - 1;
}

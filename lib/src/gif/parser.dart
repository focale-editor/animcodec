part of '../gif.dart';

/// Parsed graphic-control values applying to one image descriptor.
final class _GifGraphicControl {
  /// Default values used when no graphic-control extension precedes a frame.
  static const _GifGraphicControl defaults = _GifGraphicControl(
    delayCentiseconds: 0,
    disposal: AnimationFrameDisposal.keep,
  );

  /// Encoded presentation delay in hundredths of a second.
  final int delayCentiseconds;

  /// Canvas operation performed after presentation.
  final AnimationFrameDisposal disposal;

  /// Transparent palette index, when enabled.
  final int? transparentIndex;

  /// Creates parsed graphic-control values.
  const _GifGraphicControl({
    required this.delayCentiseconds,
    required this.disposal,
    this.transparentIndex,
  });
}

/// One parsed GIF image descriptor and its still-compressed pixels.
final class _ParsedGifFrame {
  /// Horizontal offset in the logical screen.
  final int left;

  /// Vertical offset in the logical screen.
  final int top;

  /// Descriptor width.
  final int width;

  /// Descriptor height.
  final int height;

  /// Packed descriptor flags.
  final int imagePacked;

  /// Optional local colour table as tightly packed RGB entries.
  final Uint8List? localColorTable;

  /// GIF LZW minimum code size.
  final int minimumCodeSize;

  /// Original length-prefixed compressed sub-block chain, including terminator.
  final Uint8List imageSubBlocks;

  /// Graphic-control values applying to this descriptor.
  final _GifGraphicControl control;

  /// Creates one parsed compressed frame.
  const _ParsedGifFrame({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.imagePacked,
    required this.localColorTable,
    required this.minimumCodeSize,
    required this.imageSubBlocks,
    required this.control,
  });
}

/// Parsed GIF container information shared by inspection, decode and remuxing.
final class _ParsedGif {
  /// Logical screen width.
  final int width;

  /// Logical screen height.
  final int height;

  /// Packed logical-screen flags.
  final int screenPacked;

  /// Background palette index.
  final int backgroundIndex;

  /// Pixel aspect byte retained for synthetic frames.
  final int pixelAspect;

  /// Optional global colour table as tightly packed RGB entries.
  final Uint8List? globalColorTable;

  /// Ordered compressed frame descriptors.
  final List<_ParsedGifFrame> frames;

  /// Netscape loop value, where zero means forever and `null` means absent.
  final int? loopCount;

  /// Whether the data ended before its trailer, after at least one frame.
  final bool truncated;

  /// Creates parsed GIF container state.
  const _ParsedGif._({
    required this.width,
    required this.height,
    required this.screenPacked,
    required this.backgroundIndex,
    required this.pixelAspect,
    required this.globalColorTable,
    required this.frames,
    required this.loopCount,
    required this.truncated,
  });

  /// Parses and validates a GIF block stream without inflating pixels.
  ///
  /// Browsers and Skia display every complete frame of a file that stops early,
  /// which is common for downloads and screen captures that were cut short. The
  /// same tolerance applies here: once one complete frame has been read, a
  /// missing trailer or a partial trailing block ends the sequence instead of
  /// rejecting it. A file without any complete frame is still rejected.
  factory _ParsedGif.parse({
    required Uint8List bytes,
    required GifAnimationDecodeOptions options,
  }) {
    options.validate();
    if (bytes.lengthInBytes > options.maxEncodedBytes) {
      throw AnimationCodecException(
        message: 'Encoded GIF contains ${bytes.lengthInBytes} bytes, exceeding the ${options.maxEncodedBytes} byte limit',
        failure: AnimationCodecFailure.limitExceeded,
      );
    }
    final _GifReader reader = _GifReader(bytes: bytes);
    final Uint8List signature = reader.readBytes(6);
    final bool validSignature =
        signature.length == 6 && signature[0] == 0x47 && signature[1] == 0x49 && signature[2] == 0x46 && signature[3] == 0x38 && (signature[4] == 0x37 || signature[4] == 0x39) && signature[5] == 0x61;
    if (!validSignature) {
      throw const AnimationCodecException(message: 'Invalid GIF signature');
    }

    final int width = reader.readUint16();
    final int height = reader.readUint16();
    if (width < 1 || height < 1) {
      throw const AnimationCodecException(
        message: 'GIF dimensions must be positive and non-zero',
      );
    }
    final int canvasPixels = width * height;
    if (canvasPixels > options.maxCanvasPixels) {
      throw AnimationCodecException(
        message: 'GIF canvas contains $canvasPixels pixels, exceeding the ${options.maxCanvasPixels} pixel limit',
        failure: AnimationCodecFailure.limitExceeded,
      );
    }
    final int screenPacked = reader.readByte();
    final int backgroundIndex = reader.readByte();
    final int pixelAspect = reader.readByte();
    final Uint8List? globalColorTable = (screenPacked & 0x80) == 0 ? null : reader.readBytes(_colorTableByteLength(screenPacked));

    final List<_ParsedGifFrame> frames = [];
    _GifGraphicControl pendingControl = _GifGraphicControl.defaults;
    int? loopCount;
    bool hasTrailer = false;
    try {
      while (!hasTrailer) {
        if (reader.remaining == 0) {
          throw const AnimationCodecException(
            message: 'GIF trailer is missing',
            failure: AnimationCodecFailure.truncated,
          );
        }
        final int introducer = reader.readByte();
        switch (introducer) {
          case 0x21:
            final int label = reader.readByte();
            switch (label) {
              case 0xf9:
                pendingControl = _readGraphicControl(reader);
              case 0xff:
                loopCount = _readApplicationExtension(reader) ?? loopCount;
              case 0x01:
                final int headerLength = reader.readByte();
                reader.skip(headerLength);
                reader.skipSubBlocks();
                pendingControl = _GifGraphicControl.defaults;
              default:
                reader.skipSubBlocks();
            }
          case 0x2c:
            if (frames.length >= options.maxFrames) {
              throw AnimationCodecException(
                message: 'GIF contains more than the configured ${options.maxFrames} frame limit',
                failure: AnimationCodecFailure.limitExceeded,
              );
            }
            frames.add(
              _readFrame(
                reader,
                canvasWidth: width,
                canvasHeight: height,
                globalColorTable: globalColorTable,
                control: pendingControl,
              ),
            );
            pendingControl = _GifGraphicControl.defaults;
          case 0x3b:
            hasTrailer = true;
          default:
            throw AnimationCodecException(
              message: 'Unsupported GIF block introducer 0x${introducer.toRadixString(16)}',
            );
        }
      }
    } on AnimationCodecException catch (error) {
      // Only running out of data is forgiven, and only once something can be
      // shown: a corrupt block in the middle of a complete file stays an error.
      if (error.failure != AnimationCodecFailure.truncated || frames.isEmpty) {
        rethrow;
      }
    }
    if (frames.isEmpty) {
      throw const AnimationCodecException(message: 'GIF contains no image frame');
    }
    return _ParsedGif._(
      width: width,
      height: height,
      screenPacked: screenPacked,
      backgroundIndex: backgroundIndex,
      pixelAspect: pixelAspect,
      globalColorTable: globalColorTable,
      frames: List<_ParsedGifFrame>.unmodifiable(frames),
      loopCount: loopCount,
      truncated: !hasTrailer,
    );
  }

  /// Returns the encoded byte length of a colour table described by [packed].
  static int _colorTableByteLength(int packed) => 3 * (1 << ((packed & 0x07) + 1));

  /// Reads a graphic-control extension after its label byte.
  static _GifGraphicControl _readGraphicControl(_GifReader reader) {
    if (reader.readByte() != 4) {
      throw const AnimationCodecException(
        message: 'GIF graphic-control extension has an invalid size',
      );
    }
    final int packed = reader.readByte();
    final int delay = reader.readUint16();
    final int transparentIndex = reader.readByte();
    if (reader.readByte() != 0) {
      throw const AnimationCodecException(
        message: 'GIF graphic-control extension is not terminated',
      );
    }
    final AnimationFrameDisposal disposal = switch ((packed >> 2) & 0x07) {
      2 => AnimationFrameDisposal.background,
      3 => AnimationFrameDisposal.previous,
      _ => AnimationFrameDisposal.keep,
    };
    return _GifGraphicControl(
      delayCentiseconds: delay,
      disposal: disposal,
      transparentIndex: (packed & 0x01) == 0 ? null : transparentIndex,
    );
  }

  /// Reads an application extension and returns recognized loop metadata.
  static int? _readApplicationExtension(_GifReader reader) {
    final int identifierLength = reader.readByte();
    final String identifier = String.fromCharCodes(reader.readBytes(identifierLength));
    int? loopCount;
    bool first = true;
    while (true) {
      final int length = reader.readByte();
      if (length == 0) {
        return loopCount;
      }
      final Uint8List data = reader.readBytes(length);
      if (first && (identifier == 'NETSCAPE2.0' || identifier == 'ANIMEXTS1.0') && data.length == 3 && data[0] == 1) {
        loopCount = data[1] | (data[2] << 8);
      }
      first = false;
    }
  }

  /// Reads and validates one image descriptor and its compressed sub-blocks.
  static _ParsedGifFrame _readFrame(
    _GifReader reader, {
    required int canvasWidth,
    required int canvasHeight,
    required Uint8List? globalColorTable,
    required _GifGraphicControl control,
  }) {
    final int left = reader.readUint16();
    final int top = reader.readUint16();
    final int width = reader.readUint16();
    final int height = reader.readUint16();
    if (width < 1 || height < 1 || left + width > canvasWidth || top + height > canvasHeight) {
      throw const AnimationCodecException(
        message: 'GIF image descriptor exceeds its logical screen',
      );
    }
    final int imagePacked = reader.readByte();
    final Uint8List? localColorTable = (imagePacked & 0x80) == 0 ? null : reader.readBytes(_colorTableByteLength(imagePacked));
    if (localColorTable == null && globalColorTable == null) {
      throw const AnimationCodecException(
        message: 'GIF image has no colour table',
      );
    }
    final int minimumCodeSize = reader.readByte();
    if (minimumCodeSize < 2 || minimumCodeSize > 8) {
      throw AnimationCodecException(
        message: 'Unsupported GIF LZW minimum code size: $minimumCodeSize',
      );
    }
    return _ParsedGifFrame(
      left: left,
      top: top,
      width: width,
      height: height,
      imagePacked: imagePacked,
      localColorTable: localColorTable,
      minimumCodeSize: minimumCodeSize,
      imageSubBlocks: reader.readSubBlocks(),
      control: control,
    );
  }
}

/// Bounds-checked little-endian reader for GIF container fields.
final class _GifReader {
  /// Encoded source bytes.
  final Uint8List bytes;

  /// Typed view used for endian-aware integer access.
  final ByteData _data;

  /// Current source offset.
  int position = 0;

  /// Creates a reader at the beginning of [bytes].
  _GifReader({required this.bytes}) : _data = ByteData.sublistView(bytes);

  /// Number of unread source bytes.
  int get remaining => bytes.lengthInBytes - position;

  /// Ensures [length] bytes remain available.
  void ensure(int length) {
    if (length < 0 || length > remaining) {
      throw const AnimationCodecException(
        message: 'Encoded GIF data is truncated',
        failure: AnimationCodecFailure.truncated,
      );
    }
  }

  /// Advances over [length] bytes.
  void skip(int length) {
    ensure(length);
    position += length;
  }

  /// Reads one unsigned byte.
  int readByte() {
    ensure(1);
    return bytes[position++];
  }

  /// Reads one little-endian unsigned 16-bit value.
  int readUint16() {
    ensure(2);
    final int value = _data.getUint16(position, Endian.little);
    position += 2;
    return value;
  }

  /// Reads a view of [length] consecutive bytes.
  Uint8List readBytes(int length) {
    ensure(length);
    final Uint8List result = Uint8List.sublistView(bytes, position, position + length);
    position += length;
    return result;
  }

  /// Reads and retains one complete length-prefixed data chain.
  Uint8List readSubBlocks() {
    final BytesBuilder output = BytesBuilder(copy: false);
    while (true) {
      final int length = readByte();
      output.addByte(length);
      if (length == 0) {
        return output.takeBytes();
      }
      output.add(readBytes(length));
    }
  }

  /// Skips one complete length-prefixed data chain.
  void skipSubBlocks() {
    while (true) {
      final int length = readByte();
      if (length == 0) {
        return;
      }
      skip(length);
    }
  }
}

/// Size-bounded little-endian writer used for synthetic and final GIF data.
final class _GifWriter {
  /// Maximum encoded length accepted.
  final int maxBytes;

  /// Accumulated byte chunks.
  final BytesBuilder _builder = BytesBuilder(copy: false);

  /// Creates an empty bounded GIF writer.
  _GifWriter({required this.maxBytes});

  /// Number of bytes written so far.
  int get length => _length;

  /// Total bytes emitted, including chunks already drained by the caller.
  int _length = 0;

  /// Writes one byte after enforcing the output limit.
  void writeByte(int value) {
    _ensureCapacity(1);
    _builder.addByte(value & 0xff);
    _length++;
  }

  /// Writes one little-endian unsigned 16-bit value.
  void writeUint16(int value) {
    writeByte(value);
    writeByte(value >> 8);
  }

  /// Writes consecutive bytes after enforcing the output limit.
  void writeBytes(List<int> bytes) {
    _ensureCapacity(bytes.length);
    _builder.add(bytes);
    _length += bytes.length;
  }

  /// Returns one owned contiguous byte buffer.
  Uint8List takeBytes() => _builder.takeBytes();

  /// Rejects writes which would exceed [maxBytes].
  void _ensureCapacity(int additional) {
    if (additional < 0 || length + additional > maxBytes) {
      throw AnimationCodecException(
        message: 'Encoded GIF exceeds the configured $maxBytes byte output limit',
        failure: AnimationCodecFailure.limitExceeded,
      );
    }
  }
}

/// Builds a one-frame GIF that delegates palette lookup and LZW inflation to Imcodec.
Uint8List _buildStaticGif(_ParsedGif container, _ParsedGifFrame frame) {
  final _GifWriter output = _GifWriter(maxBytes: defaultMaximumAnimationEncodedBytes)
    ..writeBytes(const [0x47, 0x49, 0x46, 0x38, 0x39, 0x61])
    ..writeUint16(container.width)
    ..writeUint16(container.height)
    ..writeByte(container.screenPacked)
    ..writeByte(container.backgroundIndex)
    ..writeByte(container.pixelAspect);
  if (container.globalColorTable case final Uint8List table) {
    output.writeBytes(table);
  }
  if (frame.control.transparentIndex case final int transparentIndex) {
    output
      ..writeBytes(const [0x21, 0xf9, 0x04, 0x01])
      ..writeUint16(0)
      ..writeByte(transparentIndex)
      ..writeByte(0);
  }
  output
    ..writeByte(0x2c)
    ..writeUint16(frame.left)
    ..writeUint16(frame.top)
    ..writeUint16(frame.width)
    ..writeUint16(frame.height)
    ..writeByte(frame.imagePacked);
  if (frame.localColorTable case final Uint8List table) {
    output.writeBytes(table);
  }
  output
    ..writeByte(frame.minimumCodeSize)
    ..writeBytes(frame.imageSubBlocks)
    ..writeByte(0x3b);
  return output.takeBytes();
}

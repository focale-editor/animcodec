/// Classifies why an animation could not be read or written.
enum AnimationCodecFailure {
  /// The data does not follow the container format.
  malformed,

  /// The data ends before a single complete frame could be read.
  truncated,

  /// A configured size, frame-count or memory limit would be exceeded.
  limitExceeded,
}

/// Reports malformed animation data, exceeded limits or unsupported values.
final class AnimationCodecException implements Exception {
  /// Description of the failed operation.
  final String message;

  /// Original error, when one was available.
  final Object? cause;

  /// Category of the failure, so callers can tell a damaged file apart from a
  /// valid one that exceeds their resource limits.
  final AnimationCodecFailure failure;

  /// Creates an animation codec error with a human-readable [message].
  const AnimationCodecException({
    required this.message,
    this.cause,
    this.failure = AnimationCodecFailure.malformed,
  });

  @override
  String toString() => cause == null ? 'AnimationCodecException: $message' : 'AnimationCodecException: $message ($cause)';
}

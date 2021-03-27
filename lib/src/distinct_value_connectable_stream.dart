import 'dart:async';

import 'package:rxdart_ext/rxdart_ext.dart'
    show
        ConnectableStream,
        ConnectableStreamSubscription,
        PublishSubject,
        Subject,
        ValueStream,
        ValueSubject,
        ValueWrapper;

import '../distinct_value_connectable_stream.dart';
import 'distinct_value_stream.dart';

/// A [ConnectableStream] that converts a single-subscription Stream into
/// a broadcast [Stream], and provides synchronous access to the latest emitted value.
///
/// This is a combine of [ConnectableStream], [ValueStream], [ValueSubject] and [Stream.distinct].
abstract class DistinctValueConnectableStream<T> extends ConnectableStream<T>
    implements DistinctValueStream<T> {
  DistinctValueConnectableStream._(Stream<T> stream) : super(stream);

  /// Constructs a [Stream] which only begins emitting events when
  /// the [connect] method is called, this [Stream] acts like a
  /// [ValueSubject] and distinct until changed.
  ///
  /// Data events are skipped if they are equal to the previous data event.
  /// Equality is determined by the provided [equals] method. If that is omitted,
  /// the '==' operator on the last provided data element is used.
  factory DistinctValueConnectableStream(
    Stream<T> source,
    T seedValue, {
    bool Function(T previous, T next)? equals,
    bool sync = true,
  }) =>
      _DistinctValueConnectableStream<T>._(
        source,
        DistinctValueSubject(seedValue, sync: sync, equals: equals),
        equals,
      );

  @override
  DistinctValueStream<T> autoConnect(
      {void Function(StreamSubscription<T> subscription)? connection});

  @override
  StreamSubscription<T> connect();

  @override
  DistinctValueStream<T> refCount();
}

class _DistinctValueConnectableStream<T>
    extends DistinctValueConnectableStream<T> {
  final Stream<T> _source;
  final DistinctValueSubject<T> _subject;
  var _used = false;

  @override
  final bool Function(T, T) equals;

  _DistinctValueConnectableStream._(
    this._source,
    this._subject,
    bool Function(T, T)? equals,
  )   : equals = equals ?? DistinctValueStream.defaultEquals,
        super._(_subject);

  late final _connection = ConnectableStreamSubscription<T>(
    _source.listen(
      _source is DistinctValueStream<T>
          ? _subject._addWithoutComparing
          : _subject.add,
      onError: null,
      onDone: _subject.close,
    ),
    _subject,
  );

  void _checkUsed() {
    if (_used) {
      throw StateError('Cannot reuse this stream. This causes many problems.');
    }
    _used = true;
  }

  @override
  DistinctValueStream<T> autoConnect({
    void Function(StreamSubscription<T> subscription)? connection,
  }) {
    _checkUsed();

    _subject.onListen = () {
      final subscription = _connection;
      connection?.call(subscription);
    };
    _subject.onCancel = null;

    return this;
  }

  @override
  StreamSubscription<T> connect() {
    _checkUsed();

    _subject.onListen = _subject.onCancel = null;
    return _connection;
  }

  @override
  DistinctValueStream<T> refCount() {
    _checkUsed();

    ConnectableStreamSubscription<T>? subscription;

    _subject.onListen = () => subscription = _connection;
    _subject.onCancel = () => subscription?.cancel();

    return this;
  }

  @override
  Null get errorAndStackTrace => null;

  @override
  ValueWrapper<T> get valueWrapper => _subject.valueWrapper;
}

/// Provide two extension methods for [Stream]:
/// - [publishValueDistinct]
/// - [shareValueDistinct]
extension DistinctValueConnectableExtensions<T> on Stream<T> {
  /// Convert the this Stream into a [DistinctValueConnectableStream]
  /// that can be listened to multiple times, providing an initial seeded value.
  /// It will not begin emitting items from the original Stream
  /// until the `connect` method is invoked.
  ///
  /// This is useful for converting a single-subscription stream into a
  /// broadcast Stream, that also provides access to the latest value synchronously.
  ///
  /// ### Example
  ///
  /// ```
  /// final source = Stream.fromIterable([1, 2, 2, 3, 3, 3]);
  /// final connectable = source.publishValueDistinct(0);
  ///
  /// // Does not print anything at first
  /// connectable.listen(print);
  ///
  /// // Start listening to the source Stream. Will cause the previous
  /// // line to start printing 1, 2, 3
  /// final subscription = connectable.connect();
  ///
  /// // Late subscribers will not receive anything
  /// connectable.listen(print);
  ///
  /// // Can access the latest emitted value synchronously. Prints 3
  /// print(connectable.value);
  ///
  /// // Stop emitting items from the source stream and close the underlying
  /// // ValueSubject
  /// subscription.cancel();
  /// ```
  DistinctValueConnectableStream<T> publishValueDistinct(
    T seedValue, {
    bool Function(T previous, T next)? equals,
    bool sync = true,
  }) =>
      DistinctValueConnectableStream<T>(this, seedValue,
          equals: equals, sync: sync);

  /// Convert the this Stream into a new [DistinctValueStream] that can
  /// be listened to multiple times, providing an initial value.
  /// It will automatically begin emitting items when first listened to,
  /// and shut down when no listeners remain.
  ///
  /// This is useful for converting a single-subscription stream into a
  /// broadcast Stream. It's also useful for providing sync access to the latest
  /// emitted value.
  ///
  /// ### Example
  ///
  /// ```
  /// // Convert a single-subscription fromIterable stream into a broadcast
  /// // stream that will emit the latest value to any new listeners
  /// final stream = Stream
  ///   .fromIterable([1, 2, 2, 3, 3, 3])
  ///   .shareValueDistinct(0);
  ///
  /// // Start listening to the source Stream. Will start printing 1, 2, 3
  /// final subscription = stream.listen(print);
  ///
  /// // Synchronously print the latest value
  /// print(stream.value);
  ///
  /// // Subscribe again later. Does not print anything.
  /// final subscription2 = stream.listen(print);
  ///
  /// // Stop emitting items from the source stream and close the underlying
  /// // ValueSubject by cancelling all subscriptions.
  /// subscription.cancel();
  /// subscription2.cancel();
  /// ```
  DistinctValueStream<T> shareValueDistinct(
    T seedValue, {
    bool Function(T previous, T next)? equals,
    bool sync = true,
  }) =>
      publishValueDistinct(seedValue, equals: equals, sync: sync).refCount();
}

/// TODO
class DistinctValueSubject<T> extends Subject<T>
    implements DistinctValueStream<T> {
  final ValueSubject<T> _subject;

  @override
  final bool Function(T p1, T p2) equals;

  DistinctValueSubject._(
    this.equals,
    this._subject,
  ) : super(_subject, _subject.stream);

  /// TODO
  factory DistinctValueSubject(
    T seedValue, {
    bool Function(T p1, T p2)? equals,
    void Function()? onListen,
    FutureOr<void> Function()? onCancel,
    bool sync = false,
  }) {
    final subject = ValueSubject<T>(
      seedValue,
      onListen: onListen,
      onCancel: onCancel,
      sync: sync,
    );
    return DistinctValueSubject._(
        equals ?? DistinctValueStream.defaultEquals, subject);
  }

  @override
  Null get errorAndStackTrace => null;

  @override
  ValueWrapper<T> get valueWrapper => _subject.valueWrapper!;

  @override
  void add(T event) {
    if (!equals(valueWrapper.value, event)) {
      _addWithoutComparing(event);
    }
  }

  @pragma('vm:prefer-inline')
  @pragma('dart2js:tryInline')
  void _addWithoutComparing(T event) => _subject.add(event);

  @override
  Future<void> close() => _subject.close();

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      throw StateError('Cannot add error to DistinctValueSubject');

  @override
  Future<void> addStream(Stream<T> source, {bool? cancelOnError}) {
    return _subject.addStream(
      source.distinctValue(valueWrapper.value),
      cancelOnError: cancelOnError,
    );
  }

  @override
  Subject<R> createForwardingSubject<R>({
    void Function()? onListen,
    void Function()? onCancel,
    bool sync = false,
  }) =>
      PublishSubject<R>(
        onListen: onListen,
        onCancel: onCancel,
        sync: sync,
      );
}

part of 'cold_catalog_inspection.dart';

/// Held composition of an independently proved old pair and restored whole
/// state. The old app is still staged, both generations remain fenced, and no
/// commit or ordinary startup is authorized. Owns its consumed preparation,
/// including its staged native host, external readers and both actual state
/// owners. Caller-owned current native hosts, original fence and work remain
/// borrowed and must stay open until this context closes.
final class ColdRollbackStateRestoration {
  ColdRollbackStateRestoration._(
    this._preparation,
    this._state,
    this.retainedStatePath,
  );

  final ColdRollbackPreparation _preparation;
  final ColdStateRestoration _state;
  final String retainedStatePath;
  bool _closed = false, _busy = false;

  String get path => _state.path;

  Map<String, Object?> toJson() {
    if (_closed || _busy || !_preparation._consumed) {
      throw StateError(
        'complete available rollback state restoration required',
      );
    }
    return _state.toJson();
  }

  Future<void> verify() async {
    if (_closed || _busy) {
      throw StateError('available rollback state restoration required');
    }
    _busy = true;
    try {
      await _preparation._verifyRestoredState(_state, retainedStatePath);
    } finally {
      _busy = false;
    }
  }

  void close() {
    if (_busy || _preparation._busy) {
      throw StateError('rollback state restoration verification is pending');
    }
    if (_closed) return;
    _preparation._closeResources();
    _closed = true;
  }
}

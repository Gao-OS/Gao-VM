import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:gaovm_models/gaovm_models.dart';

typedef _RenamexNpNative =
    ffi.Int32 Function(
      ffi.Pointer<Utf8> source,
      ffi.Pointer<Utf8> target,
      ffi.Uint32 flags,
    );
typedef _RenamexNpDart =
    int Function(ffi.Pointer<Utf8> source, ffi.Pointer<Utf8> target, int flags);
typedef _Renameat2Native =
    ffi.Int32 Function(
      ffi.Int32 sourceDirectory,
      ffi.Pointer<Utf8> source,
      ffi.Int32 targetDirectory,
      ffi.Pointer<Utf8> target,
      ffi.Uint32 flags,
    );
typedef _Renameat2Dart =
    int Function(
      int sourceDirectory,
      ffi.Pointer<Utf8> source,
      int targetDirectory,
      ffi.Pointer<Utf8> target,
      int flags,
    );
typedef _ErrnoLocationNative = ffi.Pointer<ffi.Int32> Function();
typedef _ErrnoLocationDart = ffi.Pointer<ffi.Int32> Function();

final emergencyPublicApiRequestId = RequestId('req_00000000000000000000000000');

abstract interface class SystemHealthService {
  Future<SystemHealthStatus> liveness();

  Future<SystemHealthStatus> readiness();
}

final class SystemHealthStatus {
  SystemHealthStatus({
    required this.healthy,
    required Map<String, Object?> checks,
  }) : checks = _deepFreezeJsonObject(checks);

  final bool healthy;
  final Map<String, Object?> checks;
}

typedef PublicApiHandler =
    Future<PublicApiResponse> Function(PublicApiRequest request);
typedef PublicApiListenerError = void Function(Object error, StackTrace stack);
typedef PublicApiSocketQuarantineHook =
    Future<void> Function(
      String path,
      String quarantinePath,
      Future<void> Function() quarantineRename,
    );

abstract interface class PublicApiListenerFactory {
  PublicApiBoundListener listen({
    required ServerSocket socket,
    required void Function(HttpRequest request) onRequest,
    required PublicApiListenerError onError,
    required void Function() onDone,
  });
}

final class PublicApiBoundListener {
  const PublicApiBoundListener({
    required this.server,
    required this.subscription,
  });

  final HttpServer server;
  final StreamSubscription<HttpRequest> subscription;
}

final class DartPublicApiListenerFactory implements PublicApiListenerFactory {
  const DartPublicApiListenerFactory();

  @override
  PublicApiBoundListener listen({
    required ServerSocket socket,
    required void Function(HttpRequest request) onRequest,
    required PublicApiListenerError onError,
    required void Function() onDone,
  }) {
    final server = HttpServer.listenOn(socket);
    try {
      final subscription = server.listen(
        onRequest,
        onError: onError,
        onDone: onDone,
      );
      return PublicApiBoundListener(server: server, subscription: subscription);
    } catch (_) {
      unawaited(server.close(force: true).catchError((Object _) => server));
      rethrow;
    }
  }
}

final class PublicApiRequest {
  PublicApiRequest({
    required this.requestId,
    required this.method,
    required this.uri,
    required Map<String, List<String>> headers,
    required this.jsonBody,
    Map<String, String> pathParameters = const {},
    List<int> bodyBytes = const [],
    bool allowsExtendedWait = false,
  }) : headers = Map<String, List<String>>.unmodifiable(headers),
       pathParameters = Map<String, String>.unmodifiable(pathParameters),
       bodyBytes = List<int>.unmodifiable(bodyBytes),
       _allowsExtendedWait = allowsExtendedWait;

  final RequestId requestId;
  final String method;
  final Uri uri;
  final Map<String, List<String>> headers;
  final JsonObjectValue? jsonBody;
  final Map<String, String> pathParameters;
  final List<int> bodyBytes;
  final bool _allowsExtendedWait;
  Duration? _waitTimeout;
  bool _responseDeadlineSelected = false;

  /// Extends only a route explicitly registered as a wait endpoint. Callers
  /// must invoke this after validating the public wait request and before the
  /// first asynchronous wait boundary.
  void extendResponseDeadlineForWait(Duration timeout) {
    if (!_allowsExtendedWait) {
      throw StateError('this route cannot extend its response deadline');
    }
    if (_responseDeadlineSelected) {
      throw StateError('the response deadline was already selected');
    }
    if (_waitTimeout != null) {
      throw StateError('the wait response deadline was already configured');
    }
    if (timeout <= Duration.zero || timeout > const Duration(days: 1)) {
      throw ArgumentError.value(timeout, 'timeout', 'must be in (0, 24h]');
    }
    _waitTimeout = timeout;
  }

  Duration _selectResponseDeadline(Duration ordinaryDeadline) {
    _responseDeadlineSelected = true;
    return ordinaryDeadline + (_waitTimeout ?? Duration.zero);
  }
}

final class PublicApiResponse {
  PublicApiResponse.json({
    required this.status,
    required Object body,
    Map<String, String> headers = const {},
  }) : body = body,
       contentType = ContentType.json,
       problem = null,
       headers = Map<String, String>.unmodifiable(headers);

  PublicApiResponse.problem({
    required int status,
    required ErrorCode code,
    required String type,
    required String title,
    required String detail,
    required bool retryable,
    OperationId? operationId,
    JsonObjectValue? details,
    Map<String, String> headers = const {},
  }) : status = status,
       body = const {},
       contentType = ContentType.json,
       problem = PublicApiProblem(
         status: status,
         code: code,
         type: type,
         title: title,
         detail: detail,
         retryable: retryable,
         operationId: operationId,
         details: details ?? JsonObjectValue.empty,
       ),
       headers = Map<String, String>.unmodifiable(headers);

  final int status;
  final Object body;
  final ContentType contentType;
  final PublicApiProblem? problem;
  final Map<String, String> headers;
}

final class PublicApiProblem {
  PublicApiProblem({
    required this.status,
    required this.code,
    required this.type,
    required this.title,
    required this.detail,
    required this.retryable,
    this.operationId,
    required this.details,
  }) {
    if (status < 400 || status > 599 || type.isEmpty || title.isEmpty) {
      throw ArgumentError('public API problem is invalid');
    }
  }

  final int status;
  final ErrorCode code;
  final String type;
  final String title;
  final String detail;
  final bool retryable;
  final OperationId? operationId;
  final JsonObjectValue details;
}

final class PublicApiException implements Exception {
  const PublicApiException(this.problem);

  final PublicApiProblem problem;
}

final class PublicApiRouter {
  final Map<String, Map<String, PublicApiHandler>> _routes = {};
  final Set<String> _extendedWaitRoutes = {};

  void add(
    String method,
    String path,
    PublicApiHandler handler, {
    bool allowsExtendedWait = false,
  }) {
    final normalizedMethod = method.toUpperCase();
    final segments = path.split('/');
    final parameterNames = <String>{};
    var valid = path.startsWith('/v1/');
    for (final segment in segments.skip(1)) {
      if (segment.isEmpty) valid = false;
      if (segment.contains('{') || segment.contains('}')) {
        final match = RegExp(r'^\{([a-z][a-z0-9_]*)\}$').firstMatch(segment);
        if (match == null || !parameterNames.add(match.group(1)!))
          valid = false;
      }
    }
    if (!valid) {
      throw ArgumentError.value(
        path,
        'path',
        'must be a versioned path with unique whole-segment parameters',
      );
    }
    for (final existing in _routes.keys) {
      if (existing == path) continue;
      final other = existing.split('/');
      if (segments.length != other.length) continue;
      final count = segments.where((part) => part.startsWith('{')).length;
      final otherCount = other.where((part) => part.startsWith('{')).length;
      if (count != otherCount) continue;
      final overlaps = List.generate(segments.length, (i) => i).every(
        (i) =>
            segments[i] == other[i] ||
            segments[i].startsWith('{') ||
            other[i].startsWith('{'),
      );
      if (overlaps)
        throw ArgumentError('ambiguous route templates: $existing and $path');
    }
    final methods = _routes.putIfAbsent(path, () => {});
    if (methods.containsKey(normalizedMethod)) {
      throw StateError('$normalizedMethod $path is already registered');
    }
    methods[normalizedMethod] = handler;
    if (allowsExtendedWait) {
      _extendedWaitRoutes.add('$normalizedMethod $path');
    }
  }

  String? _matchingPath(String path) {
    if (_routes.containsKey(path)) return path;
    final parts = path.split('/');
    String? best;
    var bestParameterCount = 1 << 30;
    for (final template in _routes.keys) {
      final segments = template.split('/');
      if (segments.length != parts.length) continue;
      var matches = true;
      var count = 0;
      for (var i = 0; i < segments.length; i++) {
        if (segments[i].startsWith('{')) {
          count++;
          if (parts[i].isEmpty) matches = false;
        } else if (segments[i] != parts[i]) {
          matches = false;
        }
      }
      if (matches && count < bestParameterCount) {
        best = template;
        bestParameterCount = count;
      }
    }
    return best;
  }

  Map<String, String> pathParameters(String path) {
    final template = _matchingPath(path);
    if (template == null) return const {};
    final segments = template.split('/');
    final parts = path.split('/');
    return Map.unmodifiable({
      for (var i = 0; i < segments.length; i++)
        if (segments[i].startsWith('{'))
          segments[i].substring(1, segments[i].length - 1): parts[i],
    });
  }

  bool containsPath(String path) => _matchingPath(path) != null;

  Set<String> allowedMethods(String path) =>
      Set<String>.unmodifiable(_routes[_matchingPath(path)]?.keys ?? const []);

  PublicApiHandler? handler(String method, String path) =>
      _routes[_matchingPath(path)]?[method.toUpperCase()];

  bool allowsExtendedWait(String method, String path) {
    final template = _matchingPath(path);
    return template != null &&
        _extendedWaitRoutes.contains('${method.toUpperCase()} $template');
  }
}

final class PublicApiServer {
  PublicApiServer({
    required this.socketPath,
    required Map<String, Object?> openApiDocument,
    required SystemHealthService systemHealth,
    PublicApiRouter? router,
    PublicApiListenerFactory listenerFactory =
        const DartPublicApiListenerFactory(),
    RequestId Function()? newRequestId,
    String Function()? newSocketToken,
    PublicApiSocketQuarantineHook? beforeSocketQuarantineRename,
    this.maxJsonBodyBytes = 1024 * 1024,
    this.requestDeadline = const Duration(seconds: 15),
    this.socketProbeDeadline = const Duration(milliseconds: 250),
  }) : _openApiDocument = _deepFreezeJsonObject(openApiDocument),
       _systemHealth = systemHealth,
       _router = router ?? PublicApiRouter(),
       _listenerFactory = listenerFactory,
       _newRequestId = newRequestId ?? RequestId.generate,
       _newSocketToken = newSocketToken ?? (() => RequestId.generate().value),
       _beforeSocketQuarantineRename = beforeSocketQuarantineRename {
    if (socketPath.isEmpty || !socketPath.startsWith('/')) {
      throw ArgumentError.value(
        socketPath,
        'socketPath',
        'must be a non-empty absolute Unix path',
      );
    }
    if (utf8.encode(socketPath).length >= 104) {
      throw ArgumentError.value(
        socketPath,
        'socketPath',
        'exceeds the macOS Unix socket path limit',
      );
    }
    if (maxJsonBodyBytes < 1) {
      throw ArgumentError.value(maxJsonBodyBytes, 'maxJsonBodyBytes');
    }
    if (requestDeadline <= Duration.zero) {
      throw ArgumentError.value(requestDeadline, 'requestDeadline');
    }
    if (socketProbeDeadline <= Duration.zero) {
      throw ArgumentError.value(socketProbeDeadline, 'socketProbeDeadline');
    }
  }

  final String socketPath;
  final int maxJsonBodyBytes;
  final Duration requestDeadline;
  final Duration socketProbeDeadline;
  final Map<String, Object?> _openApiDocument;
  final SystemHealthService _systemHealth;
  final PublicApiRouter _router;
  final PublicApiListenerFactory _listenerFactory;
  final RequestId Function() _newRequestId;
  final String Function() _newSocketToken;
  final PublicApiSocketQuarantineHook? _beforeSocketQuarantineRename;
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  bool _closing = false;
  bool _ownsSocket = false;
  bool _listenerTerminated = false;
  String? _generationPath;
  String? _ownerLinkPath;
  int _activeGeneration = 0;
  Completer<void>? _doneCompleter;
  Object? _fatalError;
  int _artifactSequence = 0;

  static final _pathGate = _PublicApiPathGate();

  bool get isRunning => _server != null && !_closing && !_listenerTerminated;
  Future<void> get done => _doneCompleter?.future ?? Future<void>.value();
  Object? get fatalError => _fatalError;

  Future<void> start() => _pathGate.run(socketPath, _startLocked);

  Future<void> _startLocked() async {
    if (_server != null)
      throw StateError('public API server is already started');
    _closing = false;
    _listenerTerminated = false;
    _fatalError = null;
    await _preparePrivateParent();
    await _removeSocketIfPresent();
    await _cleanupStaleOwnershipArtifacts();
    final token = _newSocketToken().replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');
    if (token.isEmpty) throw StateError('socket ownership token is empty');
    final parent = File(socketPath).parent.path;
    final privateNameBudget = 103 - utf8.encode('$parent/').length;
    if (privateNameBudget < 6) {
      throw FileSystemException(
        'socket parent path leaves no room for an ownership generation',
        parent,
      );
    }
    final suffixLength = privateNameBudget - 3 < 12
        ? privateNameBudget - 3
        : 12;
    final shortToken = token.length <= suffixLength
        ? token
        : token.substring(token.length - suffixLength);
    final generationPath = '$parent/.g.$shortToken';
    final ownerLinkPath = '$parent/.o.$shortToken';
    await _removePrivateArtifact(generationPath);
    await _removePrivateArtifact(ownerLinkPath);
    final socket = await ServerSocket.bind(
      InternetAddress(generationPath, type: InternetAddressType.unix),
      0,
      shared: false,
    );
    _generationPath = generationPath;
    _ownerLinkPath = ownerLinkPath;
    try {
      _PosixPermissions.chmod(generationPath, 0x180);
      _PosixPermissions.link(generationPath, ownerLinkPath);
      _PosixPermissions.link(generationPath, socketPath);
      _ownsSocket = true;
      _PosixPermissions.chmod(socketPath, 0x180);
      final generation = _activeGeneration + 1;
      final bound = _listenerFactory.listen(
        socket: socket,
        onRequest: (request) {
          unawaited(
            _handle(request).catchError((Object _) {
              try {
                request.response.close();
              } catch (_) {}
            }),
          );
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!_closing && generation == _activeGeneration) {
            _fatalError = error;
            _listenerTerminated = true;
          }
          unawaited(_finishUnexpectedly(generation));
        },
        onDone: () {
          if (!_closing && generation == _activeGeneration) {
            _fatalError ??= StateError(
              'public API listener closed unexpectedly',
            );
            _listenerTerminated = true;
          }
          unawaited(_finishUnexpectedly(generation));
        },
      );
      _server = bound.server;
      _subscription = bound.subscription;
      _activeGeneration = generation;
      _doneCompleter = Completer<void>();
    } catch (_) {
      await socket.close();
      try {
        await _deleteOwnedLinks();
      } finally {
        _server = null;
        _subscription = null;
        _ownsSocket = false;
        _generationPath = null;
        _ownerLinkPath = null;
        _doneCompleter = null;
        _closing = false;
        _listenerTerminated = false;
      }
      rethrow;
    }
  }

  Future<void> close() => _pathGate.run(socketPath, _closeLocked);

  Future<void> _closeLocked() async {
    if (_server == null && _subscription == null) {
      if (_ownsSocket) {
        await _deleteOwnedLinks();
        _ownsSocket = false;
        _generationPath = null;
        _ownerLinkPath = null;
      }
      return;
    }
    _closing = true;
    final server = _server;
    _server = null;
    await server?.close(force: false);
    await _subscription?.cancel();
    _subscription = null;
    if (_ownsSocket) await _deleteOwnedLinks();
    _ownsSocket = false;
    _generationPath = null;
    _ownerLinkPath = null;
    _listenerTerminated = false;
    if (!(_doneCompleter?.isCompleted ?? true)) _doneCompleter!.complete();
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    late RequestId requestId;
    try {
      requestId = _newRequestId();
    } catch (_) {
      requestId = emergencyPublicApiRequestId;
      response.headers.set('X-Request-ID', requestId.value);
      try {
        _writeProblem(
          response,
          requestId: requestId,
          status: HttpStatus.internalServerError,
          code: ErrorCode.internalError,
          type: 'request-id-unavailable',
          title: 'Internal server error',
          detail: 'The request could not be assigned a correlation ID.',
          retryable: false,
        );
      } finally {
        try {
          await response.close();
        } catch (_) {}
      }
      return;
    }
    response.headers.set('X-Request-ID', requestId.value);
    try {
      await _dispatch(request, requestId);
    } on PublicApiException catch (failure) {
      try {
        _writePublicProblem(response, requestId, failure.problem);
      } catch (_) {}
    } on _PublicApiFailure catch (failure) {
      try {
        _writeProblem(
          response,
          requestId: requestId,
          status: failure.status,
          code: ErrorCode.invalidRequest,
          type: failure.type,
          title: failure.title,
          detail: failure.detail,
          retryable: false,
        );
      } catch (_) {}
    } on TimeoutException {
      try {
        _writeProblem(
          response,
          requestId: requestId,
          status: HttpStatus.gatewayTimeout,
          code: ErrorCode.waitTimeout,
          type: 'request-deadline-exceeded',
          title: 'Request deadline exceeded',
          detail: 'The request did not complete before its deadline.',
          retryable: true,
        );
      } catch (_) {}
    } catch (error) {
      try {
        _writeProblem(
          response,
          requestId: requestId,
          status: HttpStatus.internalServerError,
          code: ErrorCode.internalError,
          type: 'internal-error',
          title: 'Internal server error',
          detail: 'The request could not be completed.',
          retryable: false,
        );
      } catch (_) {}
    } finally {
      try {
        await response.close();
      } catch (_) {
        // The client may disconnect while a response is being finalized.
      }
    }
  }

  Future<void> _dispatch(HttpRequest request, RequestId requestId) async {
    final requestStopwatch = Stopwatch()..start();
    Duration remainingOrdinaryDeadline() {
      final remaining = requestDeadline - requestStopwatch.elapsed;
      return remaining > Duration.zero ? remaining : Duration.zero;
    }

    if (request.protocolVersion != '1.1') {
      throw const _PublicApiFailure(
        status: HttpStatus.httpVersionNotSupported,
        type: 'http-version-not-supported',
        title: 'HTTP version not supported',
        detail: 'The GaoVM public API requires HTTP/1.1.',
      );
    }
    const builtInPaths = {
      '/v1/openapi.json',
      '/v1/system/live',
      '/v1/system/ready',
    };
    final builtIn = builtInPaths.contains(request.uri.path);
    final routed = _router.containsPath(request.uri.path);
    if (!builtIn && !routed) {
      _writeProblem(
        request.response,
        requestId: requestId,
        status: HttpStatus.notFound,
        code: ErrorCode.invalidRequest,
        type: 'route-not-found',
        title: 'Route not found',
        detail: 'No public API route matches ${request.uri.path}.',
        retryable: false,
      );
      return;
    }
    final allowedMethods = builtIn
        ? const {'GET'}
        : _router.allowedMethods(request.uri.path);
    if (!allowedMethods.contains(request.method)) {
      request.response.headers.set(
        HttpHeaders.allowHeader,
        (allowedMethods.toList()..sort()).join(', '),
      );
      _writeProblem(
        request.response,
        requestId: requestId,
        status: HttpStatus.methodNotAllowed,
        code: ErrorCode.invalidRequest,
        type: 'method-not-allowed',
        title: 'Method not allowed',
        detail:
            'Allowed methods: ${(allowedMethods.toList()..sort()).join(', ')}.',
        retryable: false,
      );
      return;
    }
    if (routed && !builtIn) {
      final jsonBody = await _readJsonBody(
        request,
      ).timeout(remainingOrdinaryDeadline());
      final handler = _router.handler(request.method, request.uri.path)!;
      final headers = <String, List<String>>{};
      request.headers.forEach((name, values) {
        headers[name.toLowerCase()] = List<String>.unmodifiable(values);
      });
      final apiRequest = PublicApiRequest(
        requestId: requestId,
        method: request.method,
        uri: request.uri,
        headers: headers,
        jsonBody: jsonBody.json,
        bodyBytes: jsonBody.bytes,
        pathParameters: _router.pathParameters(request.uri.path),
        allowsExtendedWait: _router.allowsExtendedWait(
          request.method,
          request.uri.path,
        ),
      );
      final response = handler(apiRequest);
      final result = await response.timeout(
        apiRequest._selectResponseDeadline(remainingOrdinaryDeadline()),
      );
      for (final entry in result.headers.entries) {
        if (entry.key.toLowerCase() == 'x-request-id') continue;
        request.response.headers.set(entry.key, entry.value);
      }
      final problem = result.problem;
      if (problem != null) {
        _writePublicProblem(request.response, requestId, problem);
      } else {
        _writeJson(request.response, result.status, result.body);
      }
      return;
    }
    switch (request.uri.path) {
      case '/v1/openapi.json':
        _writeJson(request.response, HttpStatus.ok, _openApiDocument);
      case '/v1/system/live':
        final status = await _systemHealth.liveness().timeout(
          remainingOrdinaryDeadline(),
        );
        _writeJson(
          request.response,
          status.healthy ? HttpStatus.ok : HttpStatus.serviceUnavailable,
          {
            'live': status.healthy,
            if (status.checks.isNotEmpty) 'checks': status.checks,
          },
        );
      case '/v1/system/ready':
        final status = await _systemHealth.readiness().timeout(
          remainingOrdinaryDeadline(),
        );
        _writeJson(
          request.response,
          status.healthy ? HttpStatus.ok : HttpStatus.serviceUnavailable,
          {'ready': status.healthy, 'checks': status.checks},
        );
    }
  }

  Future<({JsonObjectValue? json, List<int> bytes})> _readJsonBody(
    HttpRequest request,
  ) async {
    final contentLength = request.contentLength;
    if (contentLength > maxJsonBodyBytes) {
      throw const _PublicApiFailure(
        status: HttpStatus.requestEntityTooLarge,
        type: 'request-body-too-large',
        title: 'Request body too large',
        detail: 'The JSON request body exceeds the configured limit.',
      );
    }
    final transferEncoding = request.headers.value(
      HttpHeaders.transferEncodingHeader,
    );
    final hasBody = contentLength > 0 || transferEncoding == 'chunked';
    if (!hasBody) return (json: null, bytes: const <int>[]);
    final contentType = request.headers.contentType;
    final isMergePatch =
        request.method == 'PATCH' &&
        contentType?.mimeType == 'application/merge-patch+json';
    if (contentType?.mimeType != ContentType.json.mimeType && !isMergePatch) {
      throw const _PublicApiFailure(
        status: HttpStatus.unsupportedMediaType,
        type: 'unsupported-media-type',
        title: 'Unsupported media type',
        detail:
            'Requests must use application/json or application/merge-patch+json for PATCH.',
      );
    }
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
      if (bytes.length > maxJsonBodyBytes) {
        throw const _PublicApiFailure(
          status: HttpStatus.requestEntityTooLarge,
          type: 'request-body-too-large',
          title: 'Request body too large',
          detail: 'The JSON request body exceeds the configured limit.',
        );
      }
    }
    try {
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      if (decoded is! Map) {
        throw const FormatException('JSON body must be an object');
      }
      return (json: JsonObjectValue.fromJson(decoded), bytes: bytes);
    } on FormatException {
      throw const _PublicApiFailure(
        status: HttpStatus.badRequest,
        type: 'invalid-json',
        title: 'Invalid JSON',
        detail: 'The request body must be a valid JSON object.',
      );
    }
  }

  void _writeJson(HttpResponse response, int status, Object body) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    final bytes = utf8.encode(jsonEncode(body));
    response.contentLength = bytes.length;
    response.add(bytes);
  }

  void _writeProblem(
    HttpResponse response, {
    required RequestId requestId,
    required int status,
    required ErrorCode code,
    required String type,
    required String title,
    required String detail,
    required bool retryable,
    OperationId? operationId,
    JsonObjectValue? details,
  }) {
    _writePublicProblem(
      response,
      requestId,
      PublicApiProblem(
        status: status,
        code: code,
        type: type,
        title: title,
        detail: detail,
        retryable: retryable,
        operationId: operationId,
        details: details ?? JsonObjectValue.empty,
      ),
    );
  }

  void _writePublicProblem(
    HttpResponse response,
    RequestId requestId,
    PublicApiProblem problem,
  ) {
    response.statusCode = problem.status;
    response.headers.contentType = ContentType(
      'application',
      'problem+json',
      charset: 'utf-8',
    );
    final bytes = utf8.encode(
      jsonEncode(
        Problem(
          type: Uri.parse('https://gaovm.dev/problems/${problem.type}'),
          title: problem.title,
          status: problem.status,
          code: problem.code,
          detail: problem.detail,
          requestId: requestId,
          retryable: problem.retryable,
          operationId: problem.operationId,
          details: problem.details,
        ).toJson(),
      ),
    );
    response.contentLength = bytes.length;
    response.add(bytes);
  }

  Future<void> _removeSocketIfPresent() async {
    final type = await FileSystemEntity.type(socketPath, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.unixDomainSock) {
      throw FileSystemException(
        'refusing to remove a non-socket API path',
        socketPath,
      );
    }
    final probe = await _removeIfConfirmedStale(socketPath);
    if (probe == _SocketProbe.active) {
      throw StateError('public API socket is already active');
    }
  }

  Future<void> _preparePrivateParent() async {
    final parent = File(socketPath).parent;
    var type = await FileSystemEntity.type(parent.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await parent.create(recursive: true);
      _PosixPermissions.chmod(parent.path, 0x1c0);
      type = await FileSystemEntity.type(parent.path, followLinks: false);
    }
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'public API socket parent is not a directory',
        parent.path,
      );
    }
    final mode = (await parent.stat()).mode & 0x1ff;
    if (mode != 0x1c0) {
      throw FileSystemException(
        'public API socket parent must have mode 0700',
        parent.path,
      );
    }
  }

  Future<_SocketProbe> _probeSocket(String path) async {
    try {
      final socket = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      ).timeout(socketProbeDeadline);
      socket.destroy();
      return _SocketProbe.active;
    } on SocketException catch (error) {
      final code = error.osError?.errorCode;
      if (code != 61 && code != 111) {
        throw FileSystemException(
          'public API socket liveness probe failed closed',
          path,
          error.osError,
        );
      }
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.unixDomainSock) {
        return _SocketProbe.stale;
      }
      if (type == FileSystemEntityType.notFound) return _SocketProbe.missing;
      throw FileSystemException('socket path changed during stale probe', path);
    } on TimeoutException {
      throw FileSystemException(
        'public API socket liveness probe timed out',
        path,
      );
    }
  }

  Future<void> _cleanupStaleOwnershipArtifacts() async {
    final parent = File(socketPath).parent;
    await for (final entity in parent.list(followLinks: false)) {
      final name = entity.path.substring(entity.path.lastIndexOf('/') + 1);
      if (!(name.startsWith('.g.') ||
          name.startsWith('.o.') ||
          name.startsWith('.s.') ||
          name.startsWith('.q.'))) {
        continue;
      }
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type != FileSystemEntityType.unixDomainSock) continue;
      await _removeIfConfirmedStale(entity.path);
    }
  }

  Future<void> _removePrivateArtifact(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.unixDomainSock) {
      throw FileSystemException(
        'private socket artifact is not a socket',
        path,
      );
    }
    final probe = await _removeIfConfirmedStale(path);
    if (probe == _SocketProbe.active) {
      throw StateError('private socket generation is already active');
    }
  }

  Future<_SocketProbe> _removeIfConfirmedStale(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return _SocketProbe.missing;
    if (type != FileSystemEntityType.unixDomainSock) {
      throw FileSystemException('stale candidate is not a socket', path);
    }
    final parent = File(path).parent.path;
    final snapshotPath = await _newPrivateArtifactPath(parent, '.s.');
    var snapshotCreated = false;
    try {
      _PosixPermissions.link(path, snapshotPath);
      snapshotCreated = true;
      if (!await FileSystemEntity.identical(path, snapshotPath)) {
        throw FileSystemException('socket changed while snapshotting', path);
      }
      final probe = await _probeSocket(snapshotPath);
      if (probe != _SocketProbe.stale) return probe;
      final currentType = await FileSystemEntity.type(path, followLinks: false);
      if (currentType != FileSystemEntityType.unixDomainSock ||
          !await FileSystemEntity.identical(path, snapshotPath)) {
        throw FileSystemException(
          'socket changed after stale liveness probe',
          path,
        );
      }
      await _quarantineAndDeleteIfIdentical(
        path,
        snapshotPath,
        invokeHook: true,
      );
      return _SocketProbe.stale;
    } finally {
      if (snapshotCreated &&
          await FileSystemEntity.type(snapshotPath, followLinks: false) ==
              FileSystemEntityType.unixDomainSock) {
        await File(snapshotPath).delete();
      }
    }
  }

  Future<void> _deleteOwnedLinks() async {
    final ownerPath = _ownerLinkPath;
    if (ownerPath == null) return;
    final ownerType = await FileSystemEntity.type(
      ownerPath,
      followLinks: false,
    );
    if (ownerType != FileSystemEntityType.unixDomainSock) return;
    final parent = File(ownerPath).parent.path;
    final snapshotPath = await _newPrivateArtifactPath(parent, '.s.');
    var snapshotCreated = false;
    try {
      _PosixPermissions.link(ownerPath, snapshotPath);
      snapshotCreated = true;
      if (!await FileSystemEntity.identical(ownerPath, snapshotPath)) {
        throw FileSystemException(
          'socket owner changed while snapshotting',
          ownerPath,
        );
      }
      await _quarantineAndDeleteIfIdentical(
        socketPath,
        snapshotPath,
        invokeHook: true,
      );
      final generationPath = _generationPath;
      if (generationPath != null) {
        await _quarantineAndDeleteIfIdentical(
          generationPath,
          snapshotPath,
          invokeHook: true,
        );
      }
      await _quarantineAndDeleteIfIdentical(
        ownerPath,
        snapshotPath,
        invokeHook: true,
      );
    } finally {
      if (snapshotCreated &&
          await FileSystemEntity.type(snapshotPath, followLinks: false) ==
              FileSystemEntityType.unixDomainSock) {
        await File(snapshotPath).delete();
      }
    }
  }

  Future<String> _newPrivateArtifactPath(String parent, String prefix) async {
    final suffixLength = 103 - utf8.encode('$parent/$prefix').length;
    if (suffixLength < 1) {
      throw StateError('cannot create private socket artifact');
    }
    for (var attempt = 0; attempt < 32; attempt++) {
      final sequence = _artifactSequence++;
      final token = '${_newSocketToken()}_$sequence'.replaceAll(
        RegExp('[^A-Za-z0-9_-]'),
        '_',
      );
      final suffix = token.length <= suffixLength
          ? token
          : token.substring(token.length - suffixLength);
      final path = '$parent/$prefix$suffix';
      if (await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return path;
      }
    }
    throw StateError('cannot reserve a unique private socket artifact');
  }

  Future<bool> _quarantineAndDeleteIfIdentical(
    String path,
    String expectedPath, {
    bool invokeHook = false,
  }) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (!await FileSystemEntity.identical(path, expectedPath)) return false;
    final quarantinePath = await _newPrivateArtifactPath(
      File(path).parent.path,
      '.q.',
    );
    var renamed = false;
    Future<void> quarantineRename() async {
      if (renamed) throw StateError('socket was already quarantined');
      _PosixPermissions.renameNoReplace(path, quarantinePath);
      renamed = true;
    }

    final hook = invokeHook ? _beforeSocketQuarantineRename : null;
    if (hook == null) {
      await quarantineRename();
    } else {
      await hook(path, quarantinePath, quarantineRename);
      if (!renamed) {
        throw StateError('socket quarantine hook did not rename the socket');
      }
    }
    if (await FileSystemEntity.identical(quarantinePath, expectedPath)) {
      await File(quarantinePath).delete();
      return true;
    }

    try {
      _PosixPermissions.link(quarantinePath, path);
    } on FileSystemException catch (error) {
      throw FileSystemException(
        'socket changed before quarantine rename; replacement preserved at '
        '$quarantinePath',
        path,
        error.osError,
      );
    }
    await File(quarantinePath).delete();
    throw FileSystemException(
      'socket changed before quarantine rename and was restored',
      path,
    );
  }

  Future<void> _finishUnexpectedly(int generation) async {
    try {
      await _pathGate.run(socketPath, () async {
        if (generation != _activeGeneration || _server == null) return;
        final server = _server;
        final subscription = _subscription;
        var ownershipCleaned = !_ownsSocket;
        try {
          await server?.close(force: true);
          await subscription?.cancel();
          if (_ownsSocket) await _deleteOwnedLinks();
          ownershipCleaned = true;
        } catch (error) {
          _fatalError = _PublicApiListenerCleanupFailure(
            listenerError: _fatalError,
            cleanupError: error,
          );
        } finally {
          _server = null;
          _subscription = null;
          if (ownershipCleaned) {
            _ownsSocket = false;
            _generationPath = null;
            _ownerLinkPath = null;
          }
          if (!(_doneCompleter?.isCompleted ?? true)) {
            _doneCompleter!.complete();
          }
        }
      });
    } catch (error) {
      _fatalError = _PublicApiListenerCleanupFailure(
        listenerError: _fatalError,
        cleanupError: error,
      );
      _server = null;
      _subscription = null;
      if (!(_doneCompleter?.isCompleted ?? true)) _doneCompleter!.complete();
    }
  }
}

enum _SocketProbe { active, stale, missing }

final class _PublicApiListenerCleanupFailure implements Exception {
  const _PublicApiListenerCleanupFailure({
    required this.listenerError,
    required this.cleanupError,
  });

  final Object? listenerError;
  final Object cleanupError;
}

final class _PublicApiPathGate {
  final Map<String, Future<void>> _tails = {};

  Future<T> run<T>(String path, Future<T> Function() action) {
    final previous = _tails[path] ?? Future<void>.value();
    final completer = Completer<T>();
    late Future<void> tail;
    tail = previous
        .catchError((Object _) {})
        .then((_) async {
          try {
            completer.complete(await action());
          } catch (error, stackTrace) {
            completer.completeError(error, stackTrace);
          }
        })
        .whenComplete(() {
          if (identical(_tails[path], tail)) _tails.remove(path);
        });
    _tails[path] = tail;
    return completer.future;
  }
}

Map<String, Object?> _deepFreezeJsonObject(Map<String, Object?> source) =>
    Map<String, Object?>.unmodifiable({
      for (final entry in source.entries)
        entry.key: _deepFreezeJsonValue(entry.value),
    });

Object? _deepFreezeJsonValue(Object? value) => switch (value) {
  null || bool() || num() || String() => value,
  List() => List<Object?>.unmodifiable(value.map(_deepFreezeJsonValue)),
  Map() => _deepFreezeJsonObject(Map<String, Object?>.from(value)),
  _ => throw ArgumentError.value(value, 'JSON value', 'is not encodable'),
};

final class _PublicApiFailure implements Exception {
  const _PublicApiFailure({
    required this.status,
    required this.type,
    required this.title,
    required this.detail,
  });

  final int status;
  final String type;
  final String title;
  final String detail;
}

final class _PosixPermissions {
  static final ffi.DynamicLibrary _libc = Platform.isMacOS
      ? ffi.DynamicLibrary.open('/usr/lib/libSystem.B.dylib')
      : ffi.DynamicLibrary.open('libc.so.6');
  static final int Function(ffi.Pointer<Utf8>, int) _chmod = _libc
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Uint32),
        int Function(ffi.Pointer<Utf8>, int)
      >('chmod');
  static final int Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>) _link = _libc
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>),
        int Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>)
      >('link');
  static final _RenamexNpDart? _renamexNp = Platform.isMacOS
      ? _lookupRenamexNp()
      : null;
  static final _Renameat2Dart? _renameat2 = Platform.isLinux
      ? _lookupRenameat2()
      : null;
  static final _ErrnoLocationDart? _errnoLocation = Platform.isMacOS
      ? _lookupErrnoLocation('__error')
      : Platform.isLinux
      ? _lookupErrnoLocation('__errno_location')
      : null;

  static void chmod(String path, int mode) {
    final pointer = path.toNativeUtf8();
    try {
      if (_chmod(pointer, mode) != 0) {
        throw FileSystemException('chmod failed', path);
      }
    } finally {
      calloc.free(pointer);
    }
  }

  static void link(String source, String target) {
    final sourcePointer = source.toNativeUtf8();
    final targetPointer = target.toNativeUtf8();
    try {
      if (_link(sourcePointer, targetPointer) != 0) {
        throw FileSystemException('hard-link creation failed', target);
      }
    } finally {
      calloc.free(sourcePointer);
      calloc.free(targetPointer);
    }
  }

  static void renameNoReplace(String source, String target) {
    final sourcePointer = source.toNativeUtf8();
    final targetPointer = target.toNativeUtf8();
    try {
      final result = switch (Platform.operatingSystem) {
        'macos' when _renamexNp != null => _renamexNp!(
          sourcePointer,
          targetPointer,
          0x4,
        ),
        'linux' when _renameat2 != null => _renameat2!(
          -100,
          sourcePointer,
          -100,
          targetPointer,
          0x1,
        ),
        _ => throw FileSystemException(
          'atomic no-replace rename is unavailable',
          source,
        ),
      };
      if (result != 0) {
        final errorNumber = _errnoLocation?.call().value;
        throw FileSystemException(
          'atomic no-replace rename failed',
          source,
          errorNumber == null
              ? null
              : OSError(
                  'rename destination exists or syscall failed',
                  errorNumber,
                ),
        );
      }
    } finally {
      calloc.free(sourcePointer);
      calloc.free(targetPointer);
    }
  }

  static _RenamexNpDart? _lookupRenamexNp() {
    try {
      return _libc.lookupFunction<_RenamexNpNative, _RenamexNpDart>(
        'renamex_np',
      );
    } catch (_) {
      return null;
    }
  }

  static _Renameat2Dart? _lookupRenameat2() {
    try {
      return _libc.lookupFunction<_Renameat2Native, _Renameat2Dart>(
        'renameat2',
      );
    } catch (_) {
      return null;
    }
  }

  static _ErrnoLocationDart? _lookupErrnoLocation(String symbol) {
    try {
      return _libc.lookupFunction<_ErrnoLocationNative, _ErrnoLocationDart>(
        symbol,
      );
    } catch (_) {
      return null;
    }
  }
}

class JsonRpcErrorCode {
  static const int parseError = -32700;
  static const int invalidRequest = -32600;
  static const int methodNotFound = -32601;
  static const int invalidParams = -32602;
  static const int internalError = -32603;
  static const int handshakeFailed = -32010;
  static const int authFailed = -32011;
  static const int capabilityMismatch = -32012;
}

class JsonRpcProtocol {
  static const String version = '2.0';

  static bool isRequest(Map<String, Object?> message) =>
      message['jsonrpc'] == version &&
      message['method'] is String &&
      !message.containsKey('result') &&
      !message.containsKey('error');

  static bool isResponse(Map<String, Object?> message) =>
      message['jsonrpc'] == version &&
      message.containsKey('id') &&
      (message.containsKey('result') || message.containsKey('error'));

  static Map<String, Object?> request({
    required Object id,
    required String method,
    Object? params,
  }) {
    final out = <String, Object?>{
      'jsonrpc': version,
      'id': id,
      'method': method,
    };
    if (params != null) {
      out['params'] = params;
    }
    return out;
  }

  static Map<String, Object?> notification({
    required String method,
    Object? params,
  }) {
    final out = <String, Object?>{
      'jsonrpc': version,
      'method': method,
    };
    if (params != null) {
      out['params'] = params;
    }
    return out;
  }

  static Map<String, Object?> result({required Object? id, required Object? result}) =>
      <String, Object?>{
        'jsonrpc': version,
        'id': id,
        'result': result,
      };

  static Map<String, Object?> error({
    required Object? id,
    required int code,
    required String message,
    Object? data,
  }) {
    final err = <String, Object?>{
      'code': code,
      'message': message,
    };
    if (data != null) {
      err['data'] = data;
    }
    return <String, Object?>{
      'jsonrpc': version,
      'id': id,
      'error': err,
    };
  }
}

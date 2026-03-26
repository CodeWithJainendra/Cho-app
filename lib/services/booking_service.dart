import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/doctor_model.dart';
import '../utils/env_config.dart';

class BookingService {
  static String get _baseUrl => EnvConfig.baseUrl;
  static String get _himsApiBaseUrl => '${EnvConfig.baseUrl}/hims_api';

  // ─── Doctor APIs ──────────────────────────────────────
  static String get _doctorsUrl => '$_baseUrl/master/api/doctors';
  static String doctorByIdUrl(int id) => '$_baseUrl/master/api/doctors/$id';
  static String doctorFindUrl(int id) =>
      '$_baseUrl/registration/api/doctor/find/$id';
  static String get _grantPatientAccessUrl =>
      '$_baseUrl/appointment/api/appointments/grant-patient-access';

  static String get _patientRegisterUrl =>
      '$_baseUrl/registration/api/patient/register';
  static String patientByAbhaUrl(String abhaId) =>
      '$_baseUrl/registration/api/patient/find/${Uri.encodeComponent(abhaId)}';
  static String patientByMobileUrl(String mobile) =>
      '$_baseUrl/registration/api/patient/search/mobile/${Uri.encodeComponent(mobile)}';
  static String patientVitalsUrl(String patientId) =>
      '$_baseUrl/registration/api/patient/patient/$patientId/vitals';

  static String get _generateTokenUrl => '$_himsApiBaseUrl/abdm/generate/token';
  static String get _generatePublicKeyUrl =>
      '$_himsApiBaseUrl/abdm/generate/public-key';
  static String get _abhaSendOtpUrl =>
      '$_himsApiBaseUrl/abdm/login/abha/send-otp';
  static String get _abhaVerifyOtpUrl =>
      '$_himsApiBaseUrl/abdm/login/abha/verify-otp';
  static String get _abhaAccountUrl => '$_himsApiBaseUrl/abdm/account';

  // ─── ABHA Creation via Aadhaar (face auth + OTP) ──────
  static String get _abhaAadharSendOtpUrl =>
      '$_himsApiBaseUrl/abdm/generate/abha/aadhar/send-otp';
  static String get _abhaAadharVerifyOtpUrl =>
      '$_himsApiBaseUrl/abdm/generate/abha/aadhar/verify-otp';

  static String get _abhaSearchMobileUrl =>
      '$_baseUrl/abdm/api/enrollment/abha/search/mobile';
  static String get _mobileAbhaSendOtpUrl =>
      '$_baseUrl/abdm/api/enrollment/abha/login/request-otp';
  static String get _mobileAbhaVerifyOtpUrl =>
      '$_baseUrl/abdm/api/enrollment/abha/login/verify-otp';

  static Future<Map<String, dynamic>?> findPatientByAbha(String abhaId) async {
    final response = await _send(
      method: 'GET',
      url: patientByAbhaUrl(abhaId),
      includeAppAuth: true,
    );

    if (response.statusCode == 404) return null;
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw BookingApiException('Your session expired. Please sign in again.');
    }
    if (!_isSuccess(response.statusCode)) {
      throw BookingApiException(_extractMessage(response.body) ??
          'Unable to fetch patient details for this ABHA ID.');
    }

    final decoded = _decodeJson(response.body);
    return _extractMap(decoded);
  }

  static Future<Map<String, dynamic>?> findPatientByMobile(String mobile) async {
    final response = await _send(
      method: 'GET',
      url: patientByMobileUrl(mobile),
      includeAppAuth: true,
    );

    if (response.statusCode == 404) return null;
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw BookingApiException('Your session expired. Please sign in again.');
    }
    if (!_isSuccess(response.statusCode)) {
      throw BookingApiException(
        _extractMessage(response.body) ??
            'Unable to search patient by mobile number.',
      );
    }

    final decoded = _decodeJson(response.body);
    return _extractMap(decoded);
  }

  static Future<Map<String, dynamic>> registerPatient(
    Map<String, dynamic> payload,
  ) async {
    final response = await _send(
      method: 'POST',
      url: _patientRegisterUrl,
      body: payload,
      includeAppAuth: true,
    );

    if (!_isSuccess(response.statusCode)) {
      throw BookingApiException(
        _extractMessage(response.body) ?? 'Patient registration failed.',
      );
    }

    return _extractMap(_decodeJson(response.body)) ?? <String, dynamic>{};
  }

  // ─── Doctor List ───────────────────────────────────────
  static Future<List<Doctor>> getDoctors() async {
    debugPrint('📡 getDoctors → $_doctorsUrl');
    final response = await _send(
      method: 'GET',
      url: _doctorsUrl,
      includeAppAuth: true,
    );

    debugPrint('📡 getDoctors status: ${response.statusCode}');
    debugPrint('📡 getDoctors body (first 500): ${response.body.length > 500 ? response.body.substring(0, 500) : response.body}');

    if (!_isSuccess(response.statusCode)) {
      throw BookingApiException(
        _extractMessage(response.body) ?? 'Failed to fetch doctors (HTTP ${response.statusCode}).',
      );
    }

    final decoded = _decodeJson(response.body);
    List<dynamic> doctorsList = [];

    if (decoded is List) {
      doctorsList = decoded;
    } else if (decoded is Map<String, dynamic>) {
      final data = decoded['data'];
      // data can be a List directly, or a Map like {totalCount, doctors:[...]}
      if (data is List) {
        doctorsList = data;
      } else if (data is Map<String, dynamic>) {
        doctorsList = (data['doctors'] ?? data['results'] ?? []) as List<dynamic>;
      } else {
        doctorsList = (decoded['doctors'] ?? decoded['results'] ?? []) as List<dynamic>;
      }
      debugPrint('📡 getDoctors parsed ${doctorsList.length} doctors');
    }

    return doctorsList
        .whereType<Map<String, dynamic>>()
        .map((json) => Doctor.fromJson(json))
        .toList();
  }

  // ─── Single Doctor Detail ─────────────────────────────
  static Future<Doctor> getDoctorById(int doctorId) async {
    final response = await _send(
      method: 'GET',
      url: doctorByIdUrl(doctorId),
      includeAppAuth: true,
    );

    if (!_isSuccess(response.statusCode)) {
      throw BookingApiException(
        _extractMessage(response.body) ?? 'Failed to fetch doctor details.',
      );
    }

    final decoded = _decodeJson(response.body);
    Map<String, dynamic> doctorData;

    if (decoded is Map<String, dynamic>) {
      doctorData = (decoded['data'] is Map<String, dynamic>)
          ? decoded['data'] as Map<String, dynamic>
          : decoded;
    } else {
      throw const BookingApiException('Invalid doctor data format.');
    }

    return Doctor.fromJson(doctorData);
  }

  // ─── Doctor Find (Registration API) ─────────────────
  /// Fetch doctor from /registration/api/doctor/find/{id}
  static Future<Map<String, dynamic>> findDoctor(int doctorId) async {
    final response = await _send(
      method: 'GET',
      url: doctorFindUrl(doctorId),
      includeAppAuth: true,
    );

    if (!_isSuccess(response.statusCode)) {
      throw BookingApiException(
        _extractMessage(response.body) ?? 'Failed to find doctor.',
      );
    }

    final decoded = _decodeJson(response.body);
    if (decoded is Map<String, dynamic>) {
      return (decoded['data'] is Map<String, dynamic>)
          ? decoded['data'] as Map<String, dynamic>
          : decoded;
    }
    throw const BookingApiException('Invalid doctor find response.');
  }

  // ─── Grant Patient Access (for Video Consultation) ──
  /// Call /appointment/api/appointments/grant-patient-access
  /// Grants the patient access to the doctor's VC room.
  static Future<Map<String, dynamic>> grantPatientAccess({
    required int doctorId,
    required int patientId,
  }) async {
    final response = await _send(
      method: 'POST',
      url: _grantPatientAccessUrl,
      body: {
        'doctor_id': doctorId.toString(),
        'patient_id': patientId.toString(),
        'doctorId': doctorId.toString(),
        'patientId': patientId.toString(),
      },
      includeAppAuth: true,
    );

    if (!_isSuccess(response.statusCode)) {
      throw BookingApiException(
        _extractMessage(response.body) ??
            'Failed to grant patient access for consultation.',
      );
    }

    final decoded = _decodeJson(response.body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    return {'success': true};
  }

  static Future<Map<String, dynamic>> updatePatientVitals(
    String patientId,
    Map<String, dynamic> payload,
  ) async {
    final response = await _send(
      method: 'PUT',
      url: patientVitalsUrl(patientId),
      body: payload,
      includeAppAuth: true,
    );

    if (!_isSuccess(response.statusCode)) {
      throw BookingApiException(
        _extractMessage(response.body) ?? 'Failed to update patient vitals.',
      );
    }

    return _extractMap(_decodeJson(response.body)) ?? <String, dynamic>{};
  }

  static Future<String> generateAbdmToken() async {
    final response = await _send(method: 'POST', url: _generateTokenUrl);
    if (!_isSuccess(response.statusCode)) {
      throw BookingApiException(
        _extractMessage(response.body) ?? 'Failed to generate ABDM token.',
      );
    }

    final decoded = _decodeJson(response.body);
    final token = _readNestedString(decoded, const [
      ['data', 'accessToken'],
      ['accessToken'],
      ['data', 'token'],
      ['token'],
    ]);

    if (token == null || token.isEmpty) {
      throw const BookingApiException('ABDM token missing in response.');
    }
    return token;
  }

  static Future<String> generatePublicKey(String accessToken) async {
    final response = await _send(
      method: 'GET',
      url: _generatePublicKeyUrl,
      bearerToken: accessToken,
    );
    if (!_isSuccess(response.statusCode)) {
      throw BookingApiException(
        _extractMessage(response.body) ?? 'Failed to generate public key.',
      );
    }

    final decoded = _decodeJson(response.body);
    final key = _readNestedString(decoded, const [
      ['data', 'publicKey'],
      ['publicKey'],
      ['data', 'public_key'],
      ['public_key'],
    ]);

    if (key == null || key.isEmpty) {
      throw const BookingApiException('Public key missing in response.');
    }
    return key;
  }

  static Future<String> sendAbhaOtp({
    required String abhaId,
    required String publicKey,
    required String accessToken,
  }) async {
    final response = await _send(
      method: 'POST',
      url: _abhaSendOtpUrl,
      body: {
        'abhaId': abhaId,
        'publicKey': publicKey,
      },
      bearerToken: accessToken,
    );
    if (!_isSuccess(response.statusCode)) {
      throw BookingApiException(
        _extractMessage(response.body) ?? 'Failed to send ABHA OTP.',
      );
    }

    final decoded = _decodeJson(response.body);
    final txnId = _readNestedString(decoded, const [
      ['data', 'txnId'],
      ['txnId'],
    ]);

    if (txnId == null || txnId.isEmpty) {
      throw const BookingApiException('Transaction ID missing in OTP response.');
    }
    return txnId;
  }

  static Future<String> verifyAbhaOtp({
    required String otp,
    required String publicKey,
    required String txnId,
    required String accessToken,
  }) async {
    final response = await _send(
      method: 'POST',
      url: _abhaVerifyOtpUrl,
      body: {
        'otp': otp,
        'publicKey': publicKey,
        'txnId': txnId,
      },
      bearerToken: accessToken,
    );
    if (!_isSuccess(response.statusCode)) {
      throw BookingApiException(
        _extractMessage(response.body) ?? 'OTP verification failed.',
      );
    }

    final decoded = _decodeJson(response.body);
    final token = _readNestedString(decoded, const [
      ['data', 'token'],
      ['token'],
    ]);

    if (token == null || token.isEmpty) {
      throw const BookingApiException('Verification token missing in response.');
    }
    return token;
  }

  static Future<Map<String, dynamic>> fetchAbhaAccount({
    required String accessToken,
    required String accountToken,
  }) async {
    final response = await _send(
      method: 'GET',
      url: _abhaAccountUrl,
      bearerToken: accessToken,
      extraHeaders: {'X-Token': 'Bearer $accountToken'},
    );
    if (!_isSuccess(response.statusCode)) {
      throw BookingApiException(
        _extractMessage(response.body) ?? 'Failed to fetch ABHA account data.',
      );
    }

    return _extractMap(_decodeJson(response.body)) ?? <String, dynamic>{};
  }

  // ─── ABHA Creation: Aadhaar Send OTP ──────────────────
  /// Sends OTP to the mobile number linked with Aadhaar.
  /// Used after face authentication to complete ABHA creation.
  static Future<Map<String, dynamic>> sendAadharAbhaOtp({
    required String aadhaar,
    required String accessToken,
  }) async {
    final response = await _send(
      method: 'POST',
      url: _abhaAadharSendOtpUrl,
      body: {'aadhaar': aadhaar},
      bearerToken: accessToken,
    );
    if (!_isSuccess(response.statusCode)) {
      throw BookingApiException(
        _extractMessage(response.body) ??
            'Failed to send Aadhaar OTP (HTTP ${response.statusCode}).',
      );
    }

    final decoded = _decodeJson(response.body);
    return _extractMap(decoded) ?? <String, dynamic>{};
  }

  // ─── ABHA Creation: Aadhaar Verify OTP ────────────────
  /// Verifies the OTP and returns the ABHA account data.
  static Future<Map<String, dynamic>> verifyAadharAbhaOtp({
    required String otp,
    required String txnId,
    required String accessToken,
  }) async {
    final response = await _send(
      method: 'POST',
      url: _abhaAadharVerifyOtpUrl,
      body: {'otp': otp, 'txnId': txnId},
      bearerToken: accessToken,
    );
    if (!_isSuccess(response.statusCode)) {
      throw BookingApiException(
        _extractMessage(response.body) ??
            'OTP verification failed (HTTP ${response.statusCode}).',
      );
    }

    final decoded = _decodeJson(response.body);
    return _extractMap(decoded) ?? <String, dynamic>{};
  }

  static Future<Map<String, dynamic>> searchAbhaByMobile(String mobile) async {
    final response = await _send(
      method: 'POST',
      url: _abhaSearchMobileUrl,
      body: {'mobileNumber': mobile},
      extraHeaders: const {'Authorization': 'Bearer no real token required'},
    );
    if (!_isSuccess(response.statusCode)) {
      throw BookingApiException(
        _extractMessage(response.body) ?? 'Failed to search ABHA accounts.',
      );
    }

    return _extractMap(_decodeJson(response.body)) ?? <String, dynamic>{};
  }

  static Future<String> sendMobileAbhaOtp({
    required int index,
    required String txnId,
    required String accessToken,
  }) async {
    final response = await _send(
      method: 'POST',
      url: _mobileAbhaSendOtpUrl,
      body: {
        'loginId': index.toString(),
        'txnId': txnId,
        'index': index.toString(),
      },
      bearerToken: accessToken,
    );
    if (!_isSuccess(response.statusCode)) {
      throw BookingApiException(
        _extractMessage(response.body) ?? 'Failed to send mobile ABHA OTP.',
      );
    }

    final decoded = _decodeJson(response.body);
    final newTxnId = _readNestedString(decoded, const [
      ['data', 'txnId'],
      ['txnId'],
    ]);

    return (newTxnId == null || newTxnId.isEmpty) ? txnId : newTxnId;
  }

  static Future<Map<String, dynamic>> verifyMobileAbhaOtp({
    required String otp,
    required String txnId,
    required String accessToken,
  }) async {
    final response = await _send(
      method: 'POST',
      url: _mobileAbhaVerifyOtpUrl,
      body: {'otp': otp, 'txnId': txnId},
      bearerToken: accessToken,
    );
    if (!_isSuccess(response.statusCode)) {
      throw BookingApiException(
        _extractMessage(response.body) ?? 'Failed to verify mobile OTP.',
      );
    }

    return _extractMap(_decodeJson(response.body)) ?? <String, dynamic>{};
  }

  static Future<_BookingResponse> _send({
    required String method,
    required String url,
    Map<String, dynamic>? body,
    String? bearerToken,
    Map<String, String>? extraHeaders,
    bool includeAppAuth = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final appToken = prefs.getString('auth_token');
    final cookieHeader = prefs.getString('cookies');

    final client = HttpClient();
    client.badCertificateCallback = (_, __, ___) => true;

    try {
      final uri = Uri.parse(url);
      final request = switch (method.toUpperCase()) {
        'GET' => await client.getUrl(uri),
        'PUT' => await client.putUrl(uri),
        _ => await client.postUrl(uri),
      };

      final headers = <String, String>{
        'accept': 'application/json',
        'Content-Type': 'application/json',
        'Origin': EnvConfig.baseUrl,
        'Referer': '${EnvConfig.baseUrl}/',
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept-Encoding': 'identity',
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 14; RMX3853) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
        'Sec-Fetch-Site': 'same-origin',
        'Sec-Fetch-Mode': 'cors',
        'Sec-Fetch-Dest': 'empty',
        'Connection': 'keep-alive',
        'sec-ch-ua':
            '"Not_A Brand";v="8", "Chromium";v="120", "Google Chrome";v="120"',
        'sec-ch-ua-mobile': '?1',
        'sec-ch-ua-platform': '"Android"',
      };

      if (includeAppAuth && appToken != null && appToken.isNotEmpty) {
        headers['Authorization'] = 'Bearer $appToken';
      }
      if (bearerToken != null && bearerToken.isNotEmpty) {
        headers['Authorization'] = 'Bearer $bearerToken';
      }
      if (cookieHeader != null && cookieHeader.isNotEmpty) {
        headers['Cookie'] = cookieHeader;
      }
      if (extraHeaders != null) {
        headers.addAll(extraHeaders);
      }

      headers.forEach(request.headers.set);

      if (body != null && method.toUpperCase() != 'GET') {
        request.write(jsonEncode(body));
      }

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      return _BookingResponse(
        statusCode: response.statusCode,
        body: responseBody,
      );
    } finally {
      client.close();
    }
  }

  /// Sends HTTP request to EXTERNAL APIs (SAMAR, StampJar, ABDM).
  /// Uses the `http` package (NOT dart:io HttpClient) to exactly match
  /// React Native fetch() behavior:
  ///  - Content-Type is exactly `application/json` (no charset suffix)
  ///  - Uses Content-Length (never chunked Transfer-Encoding)
  ///  - No extra headers like Accept, Origin, Referer, or Cookie
  static Future<_BookingResponse> _sendExternal({
    required String method,
    required String url,
    Map<String, dynamic>? body,
    String? bearerToken,
    Map<String, String>? extraHeaders,
  }) async {
    final uri = Uri.parse(url);

    // Build headers exactly like JS fetch() — only what we explicitly set
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };

    if (bearerToken != null && bearerToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $bearerToken';
    }
    if (extraHeaders != null) {
      headers.addAll(extraHeaders);
    }

    // Encode body as raw bytes so the http package does NOT append
    // "; charset=utf-8" to our Content-Type header. This matches
    // exactly what JS fetch() sends: Content-Type: application/json
    final List<int>? bodyBytes =
        (body != null && method.toUpperCase() != 'GET')
            ? utf8.encode(jsonEncode(body))
            : null;

    // Log the exact request for debugging
    debugPrint('═══ _sendExternal REQUEST ═══');
    debugPrint('  URL: $url');
    debugPrint('  Method: $method');
    debugPrint('  Headers: $headers');
    if (bodyBytes != null) debugPrint('  Body: ${utf8.decode(bodyBytes)}');
    debugPrint('═══════════════════════════');

    http.Response response;

    switch (method.toUpperCase()) {
      case 'GET':
        response = await http.get(uri, headers: headers);
        break;
      case 'PUT':
        response = await http.put(uri, headers: headers, body: bodyBytes);
        break;
      default:
        response = await http.post(uri, headers: headers, body: bodyBytes);
        break;
    }

    debugPrint('═══ _sendExternal RESPONSE ═══');
    debugPrint('  Status: ${response.statusCode}');
    debugPrint('  Response Headers: ${response.headers}');
    debugPrint('  Body: ${response.body}');
    debugPrint('═════════════════════════════');

    return _BookingResponse(
      statusCode: response.statusCode,
      body: response.body,
    );
  }

  static bool _isSuccess(int statusCode) =>
      statusCode >= 200 && statusCode < 300;

  static dynamic _decodeJson(String body) {
    if (body.isEmpty) return null;
    return jsonDecode(body);
  }

  static Map<String, dynamic>? _extractMap(dynamic decoded) {
    if (decoded is Map<String, dynamic>) {
      if (decoded['data'] is Map<String, dynamic>) {
        return decoded['data'] as Map<String, dynamic>;
      }
      if (decoded['body'] is Map<String, dynamic>) {
        return decoded['body'] as Map<String, dynamic>;
      }
      return decoded;
    }
    return null;
  }

  static String? _extractMessage(String body) {
    if (body.isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      final extracted = _readNestedString(decoded, const [
        ['message'],
        ['error'],
        ['body', 'message'],
        ['data', 'message'],
      ]);
      if (extracted != null &&
          extracted.toLowerCase().contains('device fingerprint mismatch')) {
        return 'Session verification failed after network change. Please sign in again.';
      }
      return extracted;
    } catch (_) {
      return null;
    }
  }

  static String? _readNestedString(
    dynamic source,
    List<List<String>> candidates,
  ) {
    for (final path in candidates) {
      dynamic cursor = source;
      var found = true;
      for (final key in path) {
        if (cursor is Map && cursor.containsKey(key)) {
          cursor = cursor[key];
        } else {
          found = false;
          break;
        }
      }
      if (found && cursor is String && cursor.isNotEmpty) {
        return cursor;
      }
    }
    return null;
  }

  // ─── SAMAR Auth Token (for Face Auth) ────────────────────
  static Future<String> getSamarAuthToken() async {
    final now = DateTime.now();
    final timestamp =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}T'
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}.000+05:30';

    final requestBody = {
      'clientId': EnvConfig.samarClientId,
      'clientSecret': EnvConfig.samarClientSecret,
      'timestamp': timestamp,
      'deviceType': 'mobile',
      'ipAddress': '127.0.0.1',
    };

    final response = await _sendExternal(
      method: 'POST',
      url: EnvConfig.samarAuthUrl,
      body: requestBody,
    );

    if (!_isSuccess(response.statusCode)) {
      throw BookingApiException(
        _extractMessage(response.body) ??
            'Failed to get SAMAR auth token (HTTP ${response.statusCode}).',
      );
    }

    final decoded = _decodeJson(response.body);
    final token = _readNestedString(decoded, const [
      ['data', 'token'],
      ['token'],
    ]);

    if (token == null || token.isEmpty) {
      throw const BookingApiException('SAMAR auth token missing in response.');
    }
    return token;
  }

  // ─── Face Auth: Get Transaction ID ──────────────────────
  static Future<String> getFaceAuthTxnId({
    required String authToken,
  }) async {
    final requestId = _generateUUID();
    final timestamp = DateTime.now().toIso8601String();

    final requestBody = {
      'meta': {
        'refid': 'face-auth-init-001',
        'ts': timestamp,
      },
    };

    final response = await _sendExternal(
      method: 'POST',
      url: EnvConfig.stampjarFaceTxnIdUrl,
      body: requestBody,
      bearerToken: authToken,
      extraHeaders: {
        'REQUEST-ID': requestId,
        'TIMESTAMP': timestamp,
        'X-CM-ID': 'sbx',
      },
    );

    if (!_isSuccess(response.statusCode)) {
      throw BookingApiException(
        _extractMessage(response.body) ??
            'Failed to generate face auth transaction ID (HTTP ${response.statusCode}).',
      );
    }

    final decoded = _decodeJson(response.body);
    String? txnId;
    if (decoded is Map<String, dynamic>) {
      txnId = decoded['txnId']?.toString();
    }

    if (txnId == null || txnId.isEmpty) {
      throw const BookingApiException(
          'Transaction ID missing in face auth response.');
    }
    return txnId;
  }

  // ─── Face Auth: STATUS CHECK ─────────────────────────────
  /// Checks if face auth was completed. Uses `sessionToken` in body
  /// (NOT consent/meta) — matches reference app's AppState listener
  /// in LoginSignupScreen.js line 566-578.
  /// This is the correct body for STATUS CHECKS.
  static Future<Map<String, dynamic>> checkFaceAuthStatus({
    required String txnId,
    required String aadhaar,
    required String mobile,
    required String authToken,
  }) async {
    final response = await _sendExternal(
      method: 'POST',
      url: EnvConfig.stampjarFaceEnrollUrl,
      body: {
        'txnId': txnId,
        'aadhaar': aadhaar,
        'mobile': mobile,
        'sessionToken': authToken,
      },
      bearerToken: authToken,
    );

    final decoded = _decodeJson(response.body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    return <String, dynamic>{
      'status': 'ERROR',
      'message': 'HTTP ${response.statusCode}: ${response.body}',
      'httpStatusCode': response.statusCode,
    };
  }

  // ─── Face Auth: ENROLLMENT (after face auth is confirmed) ─
  /// Initiates the actual enrollment. Uses consent + meta body.
  /// Only call AFTER face auth is confirmed complete.
  static Future<Map<String, dynamic>> enrollFaceAuth({
    required String txnId,
    required String aadhaar,
    required String mobile,
    required String authToken,
  }) async {
    final response = await _sendExternal(
      method: 'POST',
      url: EnvConfig.stampjarFaceEnrollUrl,
      body: {
        'txnId': txnId,
        'aadhaar': aadhaar,
        'mobile': mobile,
        'consent': {
          'code': 'abha-enrollment',
          'version': '1.4',
        },
        'meta': {
          'refid': 'face-auth-enroll-001',
          'ts': DateTime.now().toIso8601String(),
        },
      },
      bearerToken: authToken,
    );

    final decoded = _decodeJson(response.body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    return <String, dynamic>{
      'status': 'ERROR',
      'message': 'HTTP ${response.statusCode}: ${response.body}',
      'httpStatusCode': response.statusCode,
    };
  }

  // ─── UUID Generator ─────────────────────────────────────
  static String _generateUUID() {
    final random = DateTime.now().millisecondsSinceEpoch;
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replaceAllMapped(
      RegExp(r'[xy]'),
      (match) {
        final r = (random + (DateTime.now().microsecond)) % 16;
        final v = match.group(0) == 'x' ? r : (r & 0x3 | 0x8);
        return v.toRadixString(16);
      },
    );
  }
}

class BookingApiException implements Exception {
  const BookingApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _BookingResponse {
  const _BookingResponse({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final String body;
}

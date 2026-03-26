import 'dart:convert';
import 'dart:io';
import 'dart:developer' as dev;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/appointment_model.dart';
import '../utils/env_config.dart';
import 'encryption_service.dart';

class ApiService {
  static String? _authToken;
  static String? _sessionId;
  static String? _cookieHeader; // Clean "name=value; name2=value2" for Cookie header
  static Map<String, dynamic>? _userData;
  static int? _choId;

  // ─── Headers — mimic browser-native headers for server fingerprinting ──
  static Map<String, String> get _apiHeaders => {
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
    'sec-ch-ua': '"Not_A Brand";v="8", "Chromium";v="120", "Google Chrome";v="120"',
    'sec-ch-ua-mobile': '?1',
    'sec-ch-ua-platform': '"Android"',
  };

  // ─── Extract clean cookie pairs from Set-Cookie header string ──
  // Input:  "sid=abc; Path=/; HttpOnly, token=xyz; Secure"
  // Output: "sid=abc; token=xyz"
  static String _extractCookiePairs(String rawSetCookie) {
    dev.log('🍪 Raw Set-Cookie: $rawSetCookie');
    final pairs = <String, String>{};

    // The http package joins multiple Set-Cookie headers with commas.
    // But cookie values and expires dates can contain commas too.
    // Strategy: split by semicolons first, find name=value pairs,
    // filter out cookie attributes (Path, Domain, Expires, HttpOnly, Secure, SameSite, Max-Age)
    final knownAttributes = {
      'path', 'domain', 'expires', 'max-age', 'secure', 'httponly', 'samesite'
    };

    // Split the entire header by semicolons and commas
    final parts = rawSetCookie.split(RegExp(r'[;,]'));

    for (final part in parts) {
      final trimmed = part.trim();
      final eqIdx = trimmed.indexOf('=');
      if (eqIdx > 0) {
        final name = trimmed.substring(0, eqIdx).trim();
        final value = trimmed.substring(eqIdx + 1).trim();
        // Skip known cookie attributes
        if (!knownAttributes.contains(name.toLowerCase())) {
          pairs[name] = value;
        }
      }
    }

    final result = pairs.entries.map((e) => '${e.key}=${e.value}').join('; ');
    dev.log('🍪 Parsed cookies: $result');
    return result;
  }

  // ─── Make POST using dart:io HttpClient for proper cookie handling ──
  static Future<_RawResponse> _postWithCookies(String url, Map<String, String> headers, String body) async {
    final client = HttpClient();
    client.badCertificateCallback = (cert, host, port) => true; // Handle SSL
    try {
      dev.log('📤 POST $url');
      final request = await client.postUrl(Uri.parse(url));

      // Set headers (skip Content-Type which is handled separately)
      headers.forEach((key, value) {
        if (key.toLowerCase() != 'content-type') {
          request.headers.set(key, value);
        }
      });
      request.headers.contentType = ContentType('application', 'json', charset: 'utf-8');

      // Forward cookies
      if (_cookieHeader != null && _cookieHeader!.isNotEmpty) {
        request.headers.set('Cookie', _cookieHeader!);
        dev.log('🍪 Sending Cookie header: $_cookieHeader');
      }

      // Write body
      request.write(body);

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      // ── Capture cookies from response ──
      // Method 1: dart:io parsed cookies
      final parsedCookies = <String>[];
      for (final cookie in response.cookies) {
        parsedCookies.add('${cookie.name}=${cookie.value}');
        dev.log('🍪 dart:io cookie: ${cookie.name}=${cookie.value.substring(0, min(40, cookie.value.length))}...');
      }

      // Method 2: raw set-cookie header
      final rawSetCookie = response.headers.value('set-cookie');
      dev.log('🍪 Raw set-cookie header: ${rawSetCookie != null ? rawSetCookie.substring(0, min(100, rawSetCookie.length)) : 'null'}');

      // Use whichever method gives us cookies
      String newCookies;
      if (parsedCookies.isNotEmpty) {
        newCookies = parsedCookies.join('; ');
        dev.log('🍪 Using dart:io parsed cookies');
      } else if (rawSetCookie != null && rawSetCookie.isNotEmpty) {
        newCookies = _extractCookiePairs(rawSetCookie);
        dev.log('🍪 Using manually parsed cookies');
      } else {
        newCookies = '';
        dev.log('🍪 No cookies received!');
      }

      // Also check all set-cookie headers (there might be multiple)
      final allSetCookieHeaders = response.headers['set-cookie'];
      if (allSetCookieHeaders != null) {
        dev.log('🍪 All set-cookie headers (${allSetCookieHeaders.length}):');
        for (int i = 0; i < allSetCookieHeaders.length; i++) {
          dev.log('  [$i] ${allSetCookieHeaders[i].substring(0, min(80, allSetCookieHeaders[i].length))}...');
          // Parse each header individually
          final eqIdx = allSetCookieHeaders[i].indexOf('=');
          if (eqIdx > 0) {
            final semicolonIdx = allSetCookieHeaders[i].indexOf(';');
            final nameValue = semicolonIdx > 0
                ? allSetCookieHeaders[i].substring(0, semicolonIdx)
                : allSetCookieHeaders[i];
            if (!parsedCookies.contains(nameValue.trim())) {
              parsedCookies.add(nameValue.trim());
            }
          }
        }
        if (parsedCookies.isNotEmpty) {
          newCookies = parsedCookies.join('; ');
        }
      }

      // Merge with existing cookies
      if (newCookies.isNotEmpty) {
        if (_cookieHeader != null && _cookieHeader!.isNotEmpty) {
          // Merge: new cookies override existing ones with same name
          final existing = _parseCookieString(_cookieHeader!);
          final incoming = _parseCookieString(newCookies);
          existing.addAll(incoming);
          _cookieHeader = existing.entries.map((e) => '${e.key}=${e.value}').join('; ');
        } else {
          _cookieHeader = newCookies;
        }
      }

      dev.log('🍪 Final cookie state: $_cookieHeader');

      return _RawResponse(
        statusCode: response.statusCode,
        body: responseBody,
      );
    } finally {
      client.close();
    }
  }

  static Map<String, String> _parseCookieString(String cookieStr) {
    final map = <String, String>{};
    for (final pair in cookieStr.split('; ')) {
      final idx = pair.indexOf('=');
      if (idx > 0) {
        map[pair.substring(0, idx).trim()] = pair.substring(idx + 1).trim();
      }
    }
    return map;
  }

  // ═══════════════════════════════════════════════════════════
  // STEP 1: Initialize session → get sessionId + publicKey
  // ═══════════════════════════════════════════════════════════
  static Future<SessionInitResult> _initSession() async {
    try {
      final url = EnvConfig.sessionAuthUrl;
      dev.log('══════════════════════════════════════');
      dev.log('🔄 STEP 1: Session Init');
      dev.log('📤 POST $url');

      // Reset cookies for fresh session
      _cookieHeader = null;

      final response = await _postWithCookies(
        url,
        _apiHeaders,
        jsonEncode({'deviceType': 'web'}),
      );

      dev.log('📥 Status: ${response.statusCode}');
      dev.log('📄 Body preview: ${response.body.substring(0, min(200, response.body.length))}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final json = jsonDecode(response.body);
        final data = json['data'];

        final sessionId = data?['sessionId'] ??
            data?['session_id'] ??
            json['sessionId'] ??
            json['session_id'];

        final publicKey = data?['publicKey'] ??
            data?['public_key'] ??
            json['publicKey'] ??
            json['public_key'];

        dev.log('🆔 sessionId: $sessionId');
        dev.log('🔑 publicKey present: ${publicKey != null}');
        if (publicKey != null) {
          dev.log('🔑 publicKey length: ${publicKey.toString().length}');
          dev.log('🔑 publicKey first 80: ${publicKey.toString().substring(0, min(80, publicKey.toString().length))}');
        }
        dev.log('🍪 Cookies after session: $_cookieHeader');

        if (sessionId != null && publicKey != null) {
          _sessionId = sessionId.toString();
          return SessionInitResult(
            success: true,
            sessionId: sessionId.toString(),
            publicKey: publicKey.toString(),
          );
        }

        return SessionInitResult(
          success: false,
          error: 'Missing sessionId/publicKey. Keys: ${json.keys.toList()}',
        );
      }

      return SessionInitResult(
        success: false,
        error: 'HTTP ${response.statusCode}: ${response.body}',
      );
    } catch (e, stack) {
      dev.log('❌ Session init error: $e');
      dev.log('📍 $stack');
      return SessionInitResult(success: false, error: e.toString());
    }
  }

  // ═══════════════════════════════════════════════════════════
  // STEP 2 + 3: Encrypt → Login
  // ═══════════════════════════════════════════════════════════
  static Future<LoginResponse> login(String email, String password) async {
    try {
      // ── STEP 1 ──
      final session = await _initSession();
      if (!session.success) {
        return LoginResponse(
          success: false,
          message: 'Session initialization failed: ${session.error}',
        );
      }

      // ── STEP 2: Encrypt ──
      dev.log('══════════════════════════════════════');
      dev.log('🔐 STEP 2: Encrypting credentials...');
      final encryptedUsername = EncryptionService.encryptWithPublicKey(
        email,
        session.publicKey!,
      );
      final encryptedPassword = EncryptionService.encryptWithPublicKey(
        password,
        session.publicKey!,
      );
      dev.log('✅ username encrypted: ${encryptedUsername.length} base64 chars');
      dev.log('✅ password encrypted: ${encryptedPassword.length} base64 chars');
      dev.log('📊 username preview: ${encryptedUsername.substring(0, min(30, encryptedUsername.length))}...');

      // ── STEP 3: Login API ──
      dev.log('══════════════════════════════════════');
      dev.log('📤 STEP 3: Login');
      dev.log('📤 POST ${EnvConfig.loginUrl}');
      dev.log('🍪 Cookies being sent: $_cookieHeader');

      final loginBody = jsonEncode({
        'username': encryptedUsername,
        'password': encryptedPassword,
      });

      final response = await _postWithCookies(
        EnvConfig.loginUrl,
        _apiHeaders,
        loginBody,
      );

      dev.log('📥 Login status: ${response.statusCode}');
      dev.log('📄 Login body: ${response.body}');
      dev.log('══════════════════════════════════════');

      final json = jsonDecode(response.body);
      final loginResponse = LoginResponse.fromJson(json, response.statusCode);

      if (loginResponse.success) {
        _authToken = loginResponse.token;
        _userData = loginResponse.userData;
        _choId = loginResponse.choId;

        final prefs = await SharedPreferences.getInstance();
        if (loginResponse.token != null) {
          await prefs.setString('auth_token', loginResponse.token!);
        }
        if (_sessionId != null) {
          await prefs.setString('session_id', _sessionId!);
        }
        if (_cookieHeader != null) {
          await prefs.setString('cookies', _cookieHeader!);
        }
        if (_choId != null) {
          await prefs.setInt('cho_id', _choId!);
        }
        if (loginResponse.userData != null) {
          await prefs.setString('user_data', jsonEncode(loginResponse.userData));
        }
        dev.log('✅ Login successful! CHO ID: $_choId');
      } else {
        dev.log('❌ Login failed: ${loginResponse.message}');
      }

      return loginResponse;
    } catch (e, stack) {
      dev.log('❌ Login error: $e');
      dev.log('📍 $stack');
      return LoginResponse(
        success: false,
        message: 'Login failed: ${e.toString()}',
      );
    }
  }

  // ─── CHECK SESSION ───────────────────────────────────────
  static Future<bool> checkSession() async {
    try {
      final client = HttpClient();
      client.badCertificateCallback = (cert, host, port) => true;
      try {
        final request = await client.getUrl(Uri.parse(EnvConfig.checkSessionUrl));
        _apiHeaders.forEach((key, value) {
          if (key.toLowerCase() != 'content-type') {
            request.headers.set(key, value);
          }
        });
        if (_authToken != null) {
          request.headers.set('Authorization', 'Bearer $_authToken');
        }
        if (_cookieHeader != null) {
          request.headers.set('Cookie', _cookieHeader!);
        }
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode == 200) {
          final data = jsonDecode(body);
          return data['success'] == true ||
              data['status'] == true ||
              data['valid'] == true ||
              data['authenticated'] == true;
        }
        return false;
      } finally {
        client.close();
      }
    } catch (e) {
      return false;
    }
  }

  // ─── GET CHO ID ──────────────────────────────────────────
  static Future<int> getChoId() async {
    if (_choId != null) return _choId!;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('cho_id') ?? 26;
  }

  // ─── FETCH APPOINTMENTS (using dart:io for cookie support) ──
  static Future<List<Appointment>> getAppointmentsByChoId(int choId) async {
    try {
      final url = '${EnvConfig.appointmentsByChoUrl}$choId';
      final body = await _getRequest(url);
      if (body != null) {
        return _parseAppointmentList(jsonDecode(body));
      }
      return [];
    } catch (e) {
      dev.log('❌ Appointments error: $e');
      return [];
    }
  }

  static Future<List<Appointment>> getChoAppointments() async {
    try {
      final body = await _getRequest(EnvConfig.choAppointmentsUrl);
      if (body != null) {
        return _parseAppointmentList(jsonDecode(body));
      }
      return [];
    } catch (e) {
      dev.log('❌ CHO Appointments error: $e');
      return [];
    }
  }

  /// Fetch the most recent appointment for a given doctor+patient pair that
  /// has a non-empty room_id.  Used as a fallback when the Firestore
  /// notification doesn't carry the room ID back to the Flutter client.
  static Future<String?> getLatestRoomId({
    required int doctorId,
    required int patientId,
  }) async {
    try {
      final choId = await getChoId();
      final appointments = await getAppointmentsByChoId(choId);
      // Find the most recent appointment matching doctor+patient with a roomId
      for (final appt in appointments.reversed) {
        if (appt.doctorId == doctorId &&
            appt.patientId == patientId &&
            appt.roomId != null &&
            appt.roomId!.isNotEmpty) {
          return appt.roomId;
        }
      }
      // Also check rawData in case the model field wasn't populated
      for (final appt in appointments.reversed) {
        if (appt.patientId == patientId) {
          final raw = appt.rawData;
          if (raw == null) continue;
          final roomId = (raw['room_id'] ?? raw['roomId'] ?? '').toString().trim();
          if (roomId.isNotEmpty) return roomId;
        }
      }
    } catch (e) {
      dev.log('⚠️ getLatestRoomId failed: $e');
    }
    return null;
  }

  static Future<({String? roomId, int? appointmentId})> getLatestSession({
    required int doctorId,
    required int patientId,
  }) async {
    try {
      final choId = await getChoId();
      final appointments = await getAppointmentsByChoId(choId);
      for (final appt in appointments.reversed) {
        if (appt.doctorId == doctorId &&
            appt.patientId == patientId &&
            appt.roomId != null &&
            appt.roomId!.isNotEmpty &&
            appt.id != null) {
          return (roomId: appt.roomId, appointmentId: appt.id);
        }
      }

      for (final appt in appointments.reversed) {
        if (appt.patientId != patientId) continue;
        final raw = appt.rawData;
        if (raw == null) continue;
        final roomId = (raw['room_id'] ?? raw['roomId'] ?? '').toString().trim();
        final appointmentId = int.tryParse(
          (raw['appointment_id'] ?? raw['appointmentId'] ?? raw['id'] ?? '')
              .toString(),
        );
        if (roomId.isNotEmpty && appointmentId != null) {
          return (roomId: roomId, appointmentId: appointmentId);
        }
      }
    } catch (e) {
      dev.log('⚠️ getLatestSession failed: $e');
    }
    return (roomId: null, appointmentId: null);
  }

  /// Flag that dashboard can check to show re-login prompt
  static bool sessionExpired = false;

  static Future<String?> _getRequest(String url) async {
    final client = HttpClient();
    client.badCertificateCallback = (cert, host, port) => true;
    try {
      final request = await client.getUrl(Uri.parse(url));
      _apiHeaders.forEach((key, value) {
        if (key.toLowerCase() != 'content-type') {
          request.headers.set(key, value);
        }
      });
      if (_authToken != null) {
        request.headers.set('Authorization', 'Bearer $_authToken');
      }
      if (_cookieHeader != null) {
        request.headers.set('Cookie', _cookieHeader!);
      }
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      dev.log('📥 GET $url → ${response.statusCode}');

      if (response.statusCode == 401 || response.statusCode == 403) {
        dev.log('⚠️ Session expired (${response.statusCode}) for $url');
        sessionExpired = true;
      }

      if (response.statusCode == 200) return body;
      return null;
    } finally {
      client.close();
    }
  }

  static List<Appointment> _parseAppointmentList(dynamic data) {
    List<dynamic> list;
    if (data is List) {
      list = data;
    } else if (data is Map) {
      list = data['data'] ??
          data['appointments'] ??
          data['results'] ??
          data['records'] ??
          [];
      if (list is! List) list = [];
    } else {
      list = [];
    }
    return list
        .where((e) => e is Map<String, dynamic>)
        .map((e) => Appointment.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ─── LOGOUT ──────────────────────────────────────────────
  static Future<void> logout() async {
    _authToken = null;
    _sessionId = null;
    _cookieHeader = null;
    _userData = null;
    _choId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('session_id');
    await prefs.remove('cookies');
    await prefs.remove('user_data');
    await prefs.remove('cho_id');
  }

  static Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('auth_token');
    if (token == null || token.isEmpty) return false;

    // Restore saved credentials to memory
    _authToken = token;
    _sessionId = prefs.getString('session_id');
    _cookieHeader = prefs.getString('cookies');
    _choId = prefs.getInt('cho_id');

    final rawUserData = prefs.getString('user_data');
    if (rawUserData != null) {
      try {
        _userData = jsonDecode(rawUserData);
      } catch (_) {}
    }

    // We have a saved token + cho_id → trust the local session.
    // If the session truly expired, the dashboard API calls will get
    // 401/403 and we can handle it there gracefully.
    // This prevents the app from showing login every restart just
    // because the check-session endpoint returned an unexpected format.
    if (_choId != null) {
      dev.log('✅ Restored session from prefs – token present, cho_id=$_choId');

      // Try to verify session in background (non-blocking)
      // If invalid, set sessionExpired so dashboard shows re-login prompt
      checkSession().then((valid) {
        if (!valid) {
          dev.log('⚠️ Background session check failed – session expired');
          sessionExpired = true;
        } else {
          dev.log('✅ Background session check passed');
        }
      }).catchError((e) {
        dev.log('⚠️ Background session check error: $e');
      });

      return true;
    }

    // No cho_id saved — fall back to network check
    dev.log('🔄 No cho_id in prefs, falling back to checkSession()...');
    return await checkSession();
  }

  static Future<Map<String, dynamic>?> getUserData() async {
    if (_userData != null) return _userData;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('user_data');
    if (raw != null) {
      _userData = jsonDecode(raw);
      return _userData;
    }
    return null;
  }
}

int min(int a, int b) => a < b ? a : b;

class _RawResponse {
  final int statusCode;
  final String body;
  _RawResponse({required this.statusCode, required this.body});
}

class SessionInitResult {
  final bool success;
  final String? sessionId;
  final String? publicKey;
  final String? error;
  SessionInitResult({required this.success, this.sessionId, this.publicKey, this.error});
}

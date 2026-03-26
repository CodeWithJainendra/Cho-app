import 'package:flutter_dotenv/flutter_dotenv.dart';

class EnvConfig {
  static String get baseUrl => dotenv.env['BASE_URL'] ?? '';

  // Auth
  static String get sessionAuthEndpoint =>
      dotenv.env['SESSION_AUTH_ENDPOINT'] ?? '';
  static String get loginEndpoint => dotenv.env['LOGIN_ENDPOINT'] ?? '';
  static String get checkSessionEndpoint =>
      dotenv.env['CHECK_SESSION_ENDPOINT'] ?? '';

  // Appointments
  static String get appointmentsByChoEndpoint =>
      dotenv.env['APPOINTMENTS_BY_CHO_ENDPOINT'] ?? '';
  static String get choAppointmentsEndpoint =>
      dotenv.env['CHO_APPOINTMENTS_ENDPOINT'] ?? '';

  // Booking
  static String get bookingUrl => dotenv.env['BOOKING_URL'] ?? '';

  // ─── SAMAR (Auth for Face Auth Token) ───────────────────
  static String get samarBaseUrl => dotenv.env['SAMAR_BASE_URL'] ?? '';
  static String get samarAuthSessionEndpoint =>
      dotenv.env['SAMAR_AUTH_SESSION_ENDPOINT'] ?? '';
  static String get samarClientId => dotenv.env['SAMAR_CLIENT_ID'] ?? '';
  static String get samarClientSecret =>
      dotenv.env['SAMAR_CLIENT_SECRET'] ?? '';

  // ─── StampJar (Face Auth APIs) ──────────────────────────
  static String get stampjarBaseUrl => dotenv.env['STAMPJAR_BASE_URL'] ?? '';
  static String get stampjarFaceTxnIdEndpoint =>
      dotenv.env['STAMPJAR_FACE_TXNID_ENDPOINT'] ?? '';
  static String get stampjarFaceEnrollEndpoint =>
      dotenv.env['STAMPJAR_FACE_ENROLL_ENDPOINT'] ?? '';

  // ─── PHR Sandbox (Face Auth URL) ────────────────────────
  static String get phrSbxBaseUrl => dotenv.env['PHR_SBX_BASE_URL'] ?? '';
  static String get phrFaceAuthPath => dotenv.env['PHR_FACE_AUTH_PATH'] ?? '';
  static String get playStoreNdhmUrl =>
      dotenv.env['PLAY_STORE_NDHM_URL'] ?? '';

  // ─── Full URLs ───────────────────────────────────────────
  static String get sessionAuthUrl => '$baseUrl$sessionAuthEndpoint';
  static String get loginUrl => '$baseUrl$loginEndpoint';
  static String get checkSessionUrl => '$baseUrl$checkSessionEndpoint';
  static String get appointmentsByChoUrl => '$baseUrl$appointmentsByChoEndpoint';
  static String get choAppointmentsUrl => '$baseUrl$choAppointmentsEndpoint';

  // ─── SAMAR Full URL ─────────────────────────────────────
  static String get samarAuthUrl =>
      '$samarBaseUrl$samarAuthSessionEndpoint';

  // ─── StampJar Full URLs ─────────────────────────────────
  static String get stampjarFaceTxnIdUrl =>
      '$stampjarBaseUrl$stampjarFaceTxnIdEndpoint';
  static String get stampjarFaceEnrollUrl =>
      '$stampjarBaseUrl$stampjarFaceEnrollEndpoint';

  // ─── Face Auth URL Builder ──────────────────────────────
  static String faceAuthUrl(String txnId) =>
      '$phrSbxBaseUrl$phrFaceAuthPath?txnId=$txnId';

  static String bookingUrlWithChoId(int choId) => '$bookingUrl?cho_id=$choId';

  // ─── Telemedicine / Video Call ─────────────────────────
  static String get telemedicineBaseUrl {
    String normalizeTelemedicineHost(String value) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return trimmed;
      return trimmed.endsWith('/')
          ? trimmed.substring(0, trimmed.length - 1)
          : trimmed;
    }

    final configured =
        normalizeTelemedicineHost(dotenv.env['TELEMEDICINE_BASE_URL'] ?? '');
    if (configured.isNotEmpty) return configured;
    return normalizeTelemedicineHost(baseUrl);
  }
  static String get socketPath =>
      dotenv.env['SOCKET_PATH'] ?? '/telemedicine_api/socket.io';
  static String get webrtcTurnUrl => dotenv.env['WEBRTC_TURN_URL'] ?? '';
  static String get webrtcTurnUsername =>
      dotenv.env['WEBRTC_TURN_USERNAME'] ?? '';
  static String get webrtcTurnCredential =>
      dotenv.env['WEBRTC_TURN_CREDENTIAL'] ?? '';
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../services/api_service.dart';
import '../services/video_call_service.dart';

/// Full-screen WebView video consultation for CHO (Community Health Officer).
///
/// Instead of running WebRTC inside a Flutter widget (which suffers from
/// Texture/SurfaceTexture binding issues on certain Qualcomm devices), we
/// open the CHO-specific web-based consultation UI embedded in Android WebView.
/// The WebView's built-in Chromium stack handles WebRTC natively — no
/// flutter_webrtc, no EglRenderer race conditions.
///
/// IMPORTANT: CHO and Doctor use DIFFERENT endpoints:
///   CHO    → /telemed/?room=...&usertype=cho&patient_id=...&appointment_id=...
///   Doctor → /tele_back/?roomid=...&prescriptionid=...&appointmentId=...&doctorid=...&choid=...
///
/// The CHO loads /telemed/ which shows only the video call interface.
/// The Doctor loads /tele_back/ which includes the /pres/ prescription iframe.
/// When the doctor saves a prescription, the CHO receives it via REST polling
/// (the doctor's upload does NOT send a Socket.IO message to the room).
class VideoConsultationWebViewPage extends StatefulWidget {
  final String roomId;
  final int appointmentId;
  final int doctorId;
  final int choId;
  final int patientId;   // used in CHO-side URL: patient_id=...
  final String doctorName;
  // Optional: patient ABHA ID used to construct the prescription getpdf URL.
  // The server stores PDFs at: /prescription_api/getpdf/{abhaId}/{timestamp}.pdf
  final String? patientAbhaId;

  const VideoConsultationWebViewPage({
    super.key,
    required this.roomId,
    required this.appointmentId,
    required this.doctorId,
    required this.choId,
    required this.patientId,
    required this.doctorName,
    this.patientAbhaId,
  });

  @override
  State<VideoConsultationWebViewPage> createState() =>
      _VideoConsultationWebViewPageState();
}

class _VideoConsultationWebViewPageState
    extends State<VideoConsultationWebViewPage> {
  WebViewController? _controller;
  String? _authToken;

  bool _isLoading = true;
  bool _hasError = false;
  String _errorMsg = '';

  // ── Silent re-login guard ─────────────────────────────────────────────────
  // Prevents duplicate re-login attempts if multiple navigation events fire.
  bool _reLoginInProgress = false;

  // ── In-app PDF overlay (prescription viewer) ──────────────────────────────
  WebViewController? _pdfController;
  bool _pdfLoading = false;
  bool _pdfError = false;
  String _currentPdfUrl = '';

  // ── Prescription detection ────────────────────────────────────────────────
  // PRIMARY:  CHOPrescriptionBridge JS channel (WebSocket frame interception).
  // SECONDARY: Native socket onChatMessage listener (same channel as reference app).
  // TERTIARY:  Polling fallback timer that proactively fetches PDF after delay.
  Timer? _postTelemedRedirectTimer;
  Timer? _prescriptionPollTimer;
  bool _prescriptionFound = false;
  bool _nativeChatMonitorStarted = false;
  final Set<String> _seenNativeChatKeys = <String>{};

  // For keeping the screen awake during a call.
  static const _wakeChannel = MethodChannel('cho_app/wake_lock');

  @override
  void initState() {
    super.initState();
    // Hide both status bar AND bottom nav bar — true full-screen for video.
    // User can swipe to reveal them temporarily (immersiveSticky).
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _wakeChannel.invokeMethod('acquire').catchError((_) {});
    // Request camera + mic before building the WebView so Android grants them
    // automatically when the web page asks via getUserMedia.
    _requestPermissionsThenLoad();
    // NOTE: We do NOT start a native Flutter socket here.
    // The WebView's /telemed/ page handles its own WebSocket + WebRTC video.
    // A second socket from Flutter to the same room would cause conflicts
    // (duplicate participants, competing ICE negotiation).
    // Start a polling fallback: if no prescription arrives via WS/bridge
    // within 90 seconds, proactively try to fetch it via REST API.
    _startPrescriptionPollTimer();
  }

  /// Start a polling timer that repeatedly tries to fetch the prescription
  /// via REST.  Doctor typically saves the prescription within 30–60 s of
  /// starting the call.  We poll aggressively (every 15 s, starting at 10 s)
  /// so the CHO sees the PDF as soon as possible.
  void _startPrescriptionPollTimer() {
    var attempts = 0;
    const maxAttempts = 20; // up to 5 minutes of polling (20 × 15 s)
    _prescriptionPollTimer = Timer.periodic(const Duration(seconds: 15), (t) async {
      if (_prescriptionFound || !mounted) {
        t.cancel();
        return;
      }
      attempts++;
      if (attempts > maxAttempts) {
        t.cancel();
        return;
      }
      debugPrint('⏱️ PrescriptionPoll: attempt $attempts/$maxAttempts — fetching via API...');
      try {
        await _fetchAndShowPrescription(widget.appointmentId.toString());
      } catch (e) {
        debugPrint('⚠️ PrescriptionPoll error: $e');
      }
    });
  }

  Future<void> _requestPermissionsThenLoad() async {
    // 1. Load prefs + request permissions in parallel.
    final prefs = await SharedPreferences.getInstance();
    await [Permission.camera, Permission.microphone].request();

    _authToken = prefs.getString('auth_token');
    final cookieHeader = prefs.getString('cookies'); // "name1=val1; name2=val2"

    debugPrint(_authToken != null
        ? '🔑 VideoWebView: token loaded (${_authToken!.length} chars)'
        : '⚠️ VideoWebView: no auth token in prefs');

    // 2. Inject Django session cookies into the WebView cookie store
    //    so the web page's API calls are authenticated from the very first request.
    if (cookieHeader != null && cookieHeader.isNotEmpty) {
      await _injectCookies(cookieHeader);
    }

    if (mounted) _initWebView();
  }

  // NOTE: _startNativeChatMonitor has been REMOVED.
  // The WebView's /telemed/ page handles its own WebSocket connection for
  // video and real-time events. A second Flutter-side socket into the same
  // room creates a duplicate participant and causes ICE/video conflicts.
  // Prescription detection is handled by:
  //   1. The /telemed/ page's built-in Firestore listeners (for CHO usertype)
  //   2. The JS bridge injection (console.log hook in /pres/ iframe)
  //   3. The REST polling fallback (_startPrescriptionPollTimer)

  void _handleNativeSocketMessage(Map<String, dynamic> raw) {
    if (!mounted || _prescriptionFound) return;

    // Room filter: only drop if room is explicitly set to a DIFFERENT room.
    // Messages with no room field (server omits it for native socket events)
    // are allowed through so we don't miss prescription events.
    final messageRoomId =
        (raw['roomId'] ?? raw['room_id'] ?? '').toString().trim();
    if (messageRoomId.isNotEmpty &&
        messageRoomId != widget.roomId &&
        messageRoomId != 'test_room') {
      debugPrint('⚠️ NativeChat: dropping msg — wrong room: $messageRoomId (expected ${widget.roomId})');
      return;
    }

    final timestamp =
        (raw['timestamp'] ?? raw['created_at'] ?? '').toString().trim();
    final sender =
        (raw['sender_id'] ?? raw['senderId'] ?? raw['sender'] ?? '').toString();
    final dedupeKey =
        '${raw['id'] ?? ''}|$timestamp|$sender|${raw['file_name'] ?? raw['fileName'] ?? raw['content'] ?? ''}';
    if (_seenNativeChatKeys.contains(dedupeKey)) return;
    _seenNativeChatKeys.add(dedupeKey);

    var fileName =
        (raw['fileName'] ?? raw['file_name'] ?? '').toString().trim();
    var fileType =
        (raw['fileType'] ?? raw['file_type'] ?? '').toString().trim();
    var fileContent =
        (raw['fileContent'] ?? raw['file_content'] ?? '').toString().trim();
    var fileUrl =
        (raw['file_url'] ?? raw['fileUrl'] ?? '').toString().trim();
    final content = (raw['content'] ?? raw['message'] ?? '').toString().trim();
    final messageType =
        (raw['type'] ?? raw['message_type'] ?? '').toString().toLowerCase();

    if (fileUrl.startsWith('data:') && fileContent.isEmpty) {
      final comma = fileUrl.indexOf(',');
      if (comma > 0) {
        fileContent = fileUrl.substring(comma + 1);
      }
      final mimeMatch = RegExp(r'^data:([^;]+);base64,').firstMatch(fileUrl);
      if (mimeMatch != null && fileType.isEmpty) {
        fileType = mimeMatch.group(1) ?? '';
      }
    }

    final lowerFileName = fileName.toLowerCase();
    final lowerFileType = fileType.toLowerCase();
    final lowerFileUrl = fileUrl.toLowerCase();
    final lowerContent = content.toLowerCase();

    final looksLikePdf =
        lowerFileType.contains('pdf') ||
        lowerFileName.endsWith('.pdf') ||
        lowerFileUrl.startsWith('data:application/pdf') ||
        lowerFileUrl.contains('getpdf') ||
        lowerFileUrl.contains('prescription') ||
        lowerFileUrl.endsWith('.pdf') ||
        (fileContent.length > 100 && lowerFileName.endsWith('.pdf'));

    final looksLikePrescriptionText = lowerContent.contains('prescription') ||
        lowerContent.contains('getpdf') ||
        messageType.contains('file');

    debugPrint('💬 NativeChat: type=$messageType room=$messageRoomId '
        'fileName=$fileName fileType=$fileType '
        'hasFileContent=${fileContent.isNotEmpty} '
        'fileUrl=${fileUrl.substring(0, fileUrl.length.clamp(0, 120))}');

    if (!looksLikePdf && !looksLikePrescriptionText) return;

    if (fileUrl.isNotEmpty &&
        (fileUrl.startsWith('http') || fileUrl.startsWith('data:'))) {
      debugPrint('📋 NativeChat: prescription from file_url');
      _prescriptionFound = true;
      _openPdfOverlay(
        fileUrl,
        fileName: fileName.isEmpty ? 'prescription.pdf' : fileName,
      );
      return;
    }

    if (fileContent.isNotEmpty) {
      debugPrint('📋 NativeChat: prescription from base64 file_content');
      _prescriptionFound = true;
      _openPdfOverlay(
        'data:${fileType.isNotEmpty ? fileType : 'application/pdf'};base64,$fileContent',
        fileName: fileName.isEmpty ? 'prescription.pdf' : fileName,
      );
      return;
    }

    final scannedUrl = _extractPdfUrl(raw) ?? _extractPdfUrlFromText(content);
    if (scannedUrl != null && scannedUrl.isNotEmpty) {
      debugPrint('📋 NativeChat: prescription from scanned payload → $scannedUrl');
      _prescriptionFound = true;
      _openPdfOverlay(
        scannedUrl,
        fileName: fileName.isEmpty ? 'prescription.pdf' : fileName,
      );
    }
  }

  /// Parse "name1=val1; name2=val2" and set session-related cookies into the
  /// WebView cookie store for dhanvantari.net.in.
  ///
  /// We intentionally skip `csrftoken` here: Django sets a fresh csrftoken
  /// cookie in the telemed page response headers, and injecting a stale one
  /// from the saved login cookies would cause it to mismatch the server's
  /// expected value, resulting in 403 on every AJAX call.  Instead we let the
  /// server set its own csrftoken on page load and our JS patch reads it live.
  Future<void> _injectCookies(String cookieHeader) async {
    // Cookies that must NOT be pre-injected (server sets fresh values on load).
    const skipCookies = {'csrftoken', 'csrfmiddlewaretoken'};

    final cookieManager = WebViewCookieManager();
    final pairs = cookieHeader.split(';');
    for (final pair in pairs) {
      final kv = pair.trim().split('=');
      if (kv.length < 2) continue;
      final name = kv[0].trim().toLowerCase();
      final rawName = kv[0].trim();
      final value = kv.sublist(1).join('=').trim();
      if (rawName.isEmpty || value.isEmpty) continue;
      if (skipCookies.contains(name)) {
        debugPrint('🍪 Skipping $rawName (let server set fresh value)');
        continue;
      }
      try {
        await cookieManager.setCookie(
          WebViewCookie(
            name: rawName,
            value: value,
            domain: 'dhanvantari.net.in',
            path: '/',
          ),
        );
        debugPrint('🍪 WebView cookie set: $rawName (${value.length} chars)');
      } catch (e) {
        debugPrint('⚠️ Cookie set failed for $rawName: $e');
      }
    }
  }

  void _initWebView() {
    const choWebViewMode = 'CHO_TELEMED_V2';
    // URL requested by User for CHO connection:
    // https://dhanvantari.net.in/telemed/?room={roomId}&usertype=cho&patient_id=...&appointment_id=...
    final url = Uri.https(
      'dhanvantari.net.in',
      '/telemed/',
      {
        'room': widget.roomId,
        'usertype': 'cho',
        'patient_id': widget.patientId.toString(),
        'appointment_id': widget.appointmentId.toString(),
      },
    ).toString();

    debugPrint('🌐 VideoWebView[$choWebViewMode]: loading $url');

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      // ── Flutter ↔ JS bridge for prescription events ──────────────────────
      // When the web page receives a WebSocket prescription event, it would
      // normally make an Axios call to /appointment/api/…/prescription — which
      // fails with 403 because the CHO's API session ≠ a Django web session.
      // Instead, we intercept the event in JS, post the appointmentId here,
      // and Flutter fetches the prescription PDF using its own auth token.
      ..addJavaScriptChannel(
        'CHOPrescriptionBridge',
        onMessageReceived: (msg) {
          debugPrint('📋 PrescriptionBridge: received msg="${msg.message}"');
          _onPrescriptionEvent(msg.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri != null) {
              final path = uri.path.toLowerCase();

              // ── BLOCK /tele_back/ for CHO ──────────────────────────────
              // CHO must stay on /telemed/.  /tele_back/ is the DOCTOR's
              // endpoint and would show the prescription-editing UI instead
              // of the CHO's simple video-call view.  Block any redirect or
              // iframe navigation to /tele_back/.
              if (uri.host.contains('dhanvantari.net.in') &&
                  path.startsWith('/tele_back')) {
                debugPrint(
                    '🚫 VideoWebView: BLOCKED navigation to /tele_back/ (doctor endpoint) → ${request.url}');
                return NavigationDecision.prevent;
              }

              final isTelemedCallPath =
                  path.startsWith('/telemed') || path.startsWith('/pres');

              if (uri.host.contains('dhanvantari.net.in') &&
                  isTelemedCallPath) {
                _cancelPostTelemedRedirectFallback();
              }

              // Open PDF / prescription links in the in-app overlay.
              //
              // Patterns caught:
              //  • *.pdf direct file link
              //  • /prescription* — prescription API endpoint
              //  • /prescription_api/getpdf/… — direct PDF URL
              //  • viewer?url=…getpdf… or viewer?url=…prescription…
              //    (Google / custom viewer that wraps the PDF URL)
              final viewerUrl =
                  uri.queryParameters['url'] ?? uri.queryParameters['src'] ?? '';
              final isPdfLink = path.endsWith('.pdf') ||
                  path.contains('/prescription') ||
                  path.contains('getpdf') ||
                  viewerUrl.contains('prescription') ||
                  viewerUrl.contains('getpdf') ||
                  viewerUrl.endsWith('.pdf') ||
                  (uri.queryParameters.containsKey('file') &&
                      (uri.queryParameters['file'] ?? '').endsWith('.pdf'));

              if (isPdfLink) {
                _cancelPostTelemedRedirectFallback();
                // If the URL is a viewer wrapping the real PDF, extract it.
                final realUrl = viewerUrl.isNotEmpty &&
                        (viewerUrl.contains('prescription') ||
                            viewerUrl.contains('getpdf') ||
                            viewerUrl.endsWith('.pdf'))
                    ? viewerUrl
                    : request.url;
                debugPrint('📄 VideoWebView: PDF/prescription link → overlay: $realUrl');
                _openPdfOverlay(realUrl);
                return NavigationDecision.prevent;
              }

              // When the web portal navigates away from the call page
              // (/telemed or /pres) it means
              // either the call ended (redirect to /cho_module/ etc.) OR the
              // Django session expired (redirect to /login or /accounts/login).
              //
              // Two cases:
              //  • Login redirect  → silently re-login with saved credentials
              //                      and reload the telemed page.
              //  • Any other URL   → call ended, pop back to Flutter.
              if (uri.host.contains('dhanvantari.net.in') &&
                  !isTelemedCallPath) {
                final isLoginRedirect = path.contains('/login') ||
                    path.contains('/signin') ||
                    path.contains('/accounts/login');
                if (isLoginRedirect) {
                  _cancelPostTelemedRedirectFallback();
                  debugPrint(
                      '🔄 VideoWebView: session expired → starting silent re-login');
                  _silentReLogin();
                  return NavigationDecision.prevent;
                } else if (!_prescriptionFound) {
                  debugPrint(
                      '↪️ VideoWebView: holding same-domain redirect outside telemed → ${request.url}');
                  _schedulePostTelemedRedirectFallback(request.url);
                  return NavigationDecision.prevent;
                } else {
                  debugPrint(
                      '🔚 VideoWebView: prescription already handled; leaving telemed → ${request.url}');
                  if (mounted) Navigator.pop(context);
                  return NavigationDecision.prevent;
                }
              }
            }
            return NavigationDecision.navigate;
          },
          onPageStarted: (_) {
            if (mounted) setState(() => _isLoading = true);
            // Inject EARLY — before the page's own scripts execute.
            // Axios makes API calls at initialisation time, so we must
            // have our XHR/fetch patches in place before that happens.
            _injectAuthToken(isEarlyInjection: true);
          },
          onPageFinished: (url) {
            if (mounted) setState(() => _isLoading = false);
            // Inject again after full load as a safety net
            // (e.g. for lazy-loaded modules that register their own XHR).
            _injectAuthToken();
            // No native Flutter socket here. The WebView owns signaling/media,
            // and prescription detection falls back to JS bridge + REST polling.
          },
          onWebResourceError: (error) {
            // Ignore sub-frame errors (ads, analytics) — only surface main frame failures.
            if (error.isForMainFrame == true) {
              debugPrint('❌ WebView error: ${error.description}');
              if (mounted) {
                setState(() {
                  _isLoading = false;
                  _hasError = true;
                  _errorMsg = error.description;
                });
              }
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(url));

    // Android: allow media autoplay and grant camera/mic permission requests.
    final platform = _controller!.platform;
    if (platform is AndroidWebViewController) {
      platform.setMediaPlaybackRequiresUserGesture(false);

      // Grant WebRTC getUserMedia requests (camera + microphone).
      platform.setOnPlatformPermissionRequest((request) {
        request.grant();
      });

      // Note: PDF/download links are handled via onNavigationRequest above
      // (intercepts .pdf URLs and opens them externally via url_launcher).
    }

    // Trigger a rebuild so WebViewWidget is inserted into the tree.
    if (mounted) setState(() {});
  }

  /// Inject auth credentials into the WebView's JavaScript context.
  ///
  /// Called in BOTH onPageStarted (early — before page scripts run, so our
  /// XHR/fetch patches are in place before Axios initialises) AND in
  /// onPageFinished (late — as a safety net for lazy-loaded modules).
  ///
  /// Strategy:
  ///  1. Write JWT token into localStorage under every key the stack might use.
  ///  2. Monkey-patch window.fetch AND XMLHttpRequest to inject:
  ///       • Authorization: Bearer <token>   (JWT auth)
  ///       • X-CSRFToken: <csrf>             (Django CSRF — 403 without this!)
  ///     The CSRF value is read from the csrftoken cookie at call time.
  ///  3. These guards are idempotent (__choFetchPatched / __choXhrPatched) so
  ///     calling this twice is safe.
  void _injectAuthToken({bool isEarlyInjection = false}) {
    if (_controller == null) return;

    // Use empty string rather than null — we still want the XHR/fetch patch
    // to run (for CSRF injection) even when there is no Bearer token.
    final token = _authToken ?? '';

    final safeToken = token
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'")
        .replaceAll('\n', '')
        .replaceAll('\r', '');

    final phase = isEarlyInjection ? 'early' : 'late';

    final js = """
(function() {
  var token = '$safeToken';
  var phase = '$phase';
  var forcedUserType = 'cho';

  // ── 1. localStorage ──────────────────────────────────────────────────────
  // React/Vue SPAs often read the token here on boot.
  try {
    sessionStorage.setItem('userType', forcedUserType);
    sessionStorage.setItem('usertype', forcedUserType);
    localStorage.setItem('userType', forcedUserType);
    localStorage.setItem('usertype', forcedUserType);
    localStorage.setItem('role', forcedUserType);
    if (token) {
      localStorage.setItem('token', token);
      localStorage.setItem('auth_token', token);
      localStorage.setItem('access_token', token);
      localStorage.setItem('authToken', token);
    }
  } catch(e) {}

  // ── Helper: read csrftoken cookie ─────────────────────────────────────────
  // Django sets csrftoken as a non-HttpOnly cookie so JS can read it.
  // We must forward it in X-CSRFToken header or Django returns 403.
  function getCsrf() {
    try {
      var m = document.cookie.match(/(?:^|;\\s*)csrftoken=([^;]+)/);
      return m ? decodeURIComponent(m[1]) : '';
    } catch(e) { return ''; }
  }

  // ── 2. Patch window.fetch ─────────────────────────────────────────────────
  if (!window.__choFetchPatched) {
    window.__choFetchPatched = true;
    var _origFetch = window.fetch.bind(window);
    window.fetch = function(input, init) {
      init = init || {};
      try {
        var h = new Headers(init.headers || {});
        if (token && !h.has('Authorization')) h.set('Authorization', 'Bearer ' + token);
        var csrf = getCsrf();
        if (csrf && !h.has('X-CSRFToken')) h.set('X-CSRFToken', csrf);
        init.headers = h;
      } catch(e) {}
      return _origFetch(input, init);
    };
  }

  // ── 3. Patch XMLHttpRequest (Axios uses XHR, not fetch) ───────────────────
  if (!window.__choXhrPatched) {
    window.__choXhrPatched = true;
    var _origOpen  = XMLHttpRequest.prototype.open;
    var _origSend  = XMLHttpRequest.prototype.send;
    var _origSetRH = XMLHttpRequest.prototype.setRequestHeader;

    XMLHttpRequest.prototype.open = function() {
      this.__choAuthInjected = false;
      return _origOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function() {
      if (!this.__choAuthInjected) {
        this.__choAuthInjected = true;
        try {
          if (token) _origSetRH.call(this, 'Authorization', 'Bearer ' + token);
          var csrf = getCsrf();
          if (csrf) _origSetRH.call(this, 'X-CSRFToken', csrf);
        } catch(e) {}
      }
      return _origSend.apply(this, arguments);
    };
  }

  // ── 4. WebSocket CONSTRUCTOR REPLACEMENT + retroactive scanner ───────────
  //
  // WHY ALL PREVIOUS APPROACHES FAILED:
  //   • Section 4 old: addEventListener('message') patch — Socket.IO v3/v4
  //     uses ws.onmessage=, NOT addEventListener. Never fires.
  //   • Section 4c old: Object.defineProperty(WebSocket.prototype,'onmessage')
  //     — Android WebView may not support getOwnPropertyDescriptor on native
  //     prototypes, OR timing race means ws.onmessage is set before our patch.
  //   • Section 4b old: window.io() patch — io may not be on window (module
  //     scope), or io() is called before our injection runs.
  //
  // NEW APPROACH (3-layer):
  //   Layer A: Replace window.WebSocket constructor. Every new WebSocket
  //            automatically gets an addEventListener('message') observer.
  //            addEventListener works ALONGSIDE onmessage (independent).
  //   Layer B: setInterval scanner that finds WebSocket instances already
  //            created (before our patch) by scanning known Socket.IO internals.
  //   Layer C: Also patch WebSocket.prototype.onmessage setter as before
  //            (belt-and-suspenders) with safer fallback for Android WebView.
  //
  // WHAT WE DETECT:
  //   Doctor sends: socket.emit('message', {type:'chat', file_url:'data:application/pdf;base64,...'})
  //   This arrives as Socket.IO frame: 42["message",{type:"chat",file_url:"..."}]

  console.log('🚀 CHO: Section 4 starting (phase=' + phase + ')');

  // ── Shared prescription detection function ──────────────────────────────
  function _choCheckPrescription(rd) {
    try {
      if (typeof rd !== 'string' || rd.length < 5) return;

      // Log ALL WebSocket frames for diagnostics (first 200 chars)
      console.log('🔌 CHO-WS frame: ' + rd.substring(0, 200));

      // Decode Socket.IO v3/v4 frame: 42["eventName", {...data}]
      var msg = null;
      var evtName = '';
      if (rd.startsWith('42')) {
        try {
          var arr = JSON.parse(rd.substring(2));
          if (Array.isArray(arr) && arr.length >= 1) {
            evtName = String(arr[0]);
            msg = (arr.length > 1 && arr[1] && typeof arr[1] === 'object') ? arr[1] : null;
            console.log('🔌 SIO evt=' + evtName + ' data=' + JSON.stringify(msg || '').substring(0, 300));
          }
        } catch(e) {}
      } else if (rd.charAt(0) === '{') {
        try { msg = JSON.parse(rd); } catch(e) {}
      }

      if (!msg || typeof msg !== 'object') return;

      // ── Detect prescription / PDF in the message ──────────────────────
      var msgType  = String(msg.type || msg.event || msg.action || '').toLowerCase();
      var fileUrl  = String(msg.file_url || msg.fileUrl || '');
      var fileType = String(msg.fileType || msg.file_type || '').toLowerCase();
      var fileName = String(msg.fileName || msg.file_name || '').toLowerCase();
      var fileCont = String(msg.fileContent || msg.file_content || '');

      var isPrescEvent = msgType.includes('presc') || evtName.toLowerCase().includes('presc');
      var isPdfAttach  =
        fileType.includes('pdf') ||
        fileName.endsWith('.pdf') ||
        fileUrl.startsWith('data:application/pdf') ||
        (fileUrl.includes('http') && (
          fileUrl.toLowerCase().includes('getpdf') ||
          fileUrl.toLowerCase().includes('prescription') ||
          fileUrl.endsWith('.pdf'))) ||
        (fileCont.length > 100 && fileName.endsWith('.pdf'));

      // Also check nested 'data' object (some servers wrap payload)
      if (!isPrescEvent && !isPdfAttach && msg.data && typeof msg.data === 'object') {
        var d = msg.data;
        var dfu  = String(d.file_url || d.fileUrl || '');
        var dft  = String(d.fileType || d.file_type || '').toLowerCase();
        var dfn  = String(d.fileName || d.file_name || '').toLowerCase();
        isPdfAttach = dft.includes('pdf') || dfn.endsWith('.pdf') ||
          dfu.startsWith('data:application/pdf') ||
          (dfu.includes('http') && (dfu.toLowerCase().includes('getpdf') || dfu.endsWith('.pdf')));
        if (isPdfAttach) {
          fileUrl = dfu; fileType = dft; fileName = dfn;
          fileCont = String(d.fileContent || d.file_content || '');
        }
      }

      var scannedPdfUrl = _choPdfFromData(msg);
      if (!isPdfAttach && scannedPdfUrl) {
        isPdfAttach = true;
      }

      if (isPrescEvent || isPdfAttach) {
        var pdfUrl = msg.pdfUrl || msg.pdf_url || scannedPdfUrl || '';
        if (!pdfUrl && (fileUrl.startsWith('http') || fileUrl.startsWith('data:'))) pdfUrl = fileUrl;
        if (!pdfUrl && fileCont.length > 100) pdfUrl = 'data:application/pdf;base64,' + fileCont;
        var origFn = msg.fileName || msg.file_name || 'prescription.pdf';
        var apptId = msg.appointmentId || msg.appointment_id || msg.prescriptionId || '';

        console.log('📋 CHO: PRESCRIPTION DETECTED! evt=' + evtName +
          ' type=' + msgType + ' pdfUrl=' + String(pdfUrl).substring(0, 150) +
          ' isPrescEvt=' + isPrescEvent + ' isPdfAttach=' + isPdfAttach);

        if (window.CHOPrescriptionBridge) {
          window.CHOPrescriptionBridge.postMessage(JSON.stringify({
            pdfUrl: String(pdfUrl),
            appointmentId: String(apptId),
            fileName: String(origFn),
            raw: JSON.stringify(msg).substring(0, 500)
          }));
          console.log('✅ CHO: Prescription sent to Flutter bridge!');
        } else {
          console.log('⚠️ CHO: CHOPrescriptionBridge not available!');
        }
      }
    } catch(e) {
      console.log('⚠️ CHO _choCheckPrescription error: ' + e);
    }
  }

  // ── Layer A: Replace WebSocket constructor ──────────────────────────────
  // Every new WebSocket gets an addEventListener('message') observer that
  // runs our prescription check. addEventListener is independent of onmessage
  // — both fire. This avoids the onmessage setter race entirely.
  if (!window.__choWsCtorReplaced) {
    window.__choWsCtorReplaced = true;
    try {
      var _OrigWebSocket = window.WebSocket;
      var _choTrackedWs = [];
      window.__choTrackedWs = _choTrackedWs; // expose for scanner

      function _CHOWebSocket(url, protocols) {
        var ws;
        if (protocols !== undefined) {
          ws = new _OrigWebSocket(url, protocols);
        } else {
          ws = new _OrigWebSocket(url);
        }

        console.log('🔌 CHO: New WebSocket created → ' + String(url).substring(0, 100));
        _choTrackedWs.push(ws);

        // Attach passive listener — fires alongside onmessage
        ws.addEventListener('message', function(event) {
          _choCheckPrescription(event.data);
        });

        return ws;
      }

      // Preserve prototype chain so instanceof checks work
      _CHOWebSocket.prototype = _OrigWebSocket.prototype;
      _CHOWebSocket.CONNECTING = _OrigWebSocket.CONNECTING;
      _CHOWebSocket.OPEN = _OrigWebSocket.OPEN;
      _CHOWebSocket.CLOSING = _OrigWebSocket.CLOSING;
      _CHOWebSocket.CLOSED = _OrigWebSocket.CLOSED;

      window.WebSocket = _CHOWebSocket;
      window.__OrigWebSocket = _OrigWebSocket; // keep reference
      console.log('✅ CHO: WebSocket constructor replaced (Layer A active)');
    } catch(e) {
      console.log('⚠️ CHO: WebSocket constructor replace failed: ' + e);
    }
  }

  // ── Layer B: Retroactive WebSocket scanner ──────────────────────────────
  // If any WebSocket was created BEFORE our constructor replacement,
  // this scanner finds it and attaches our listener.
  if (!window.__choWsScannerStarted) {
    window.__choWsScannerStarted = true;
    var _choScanCount = 0;
    var _choAttachedWs = new Set ? new Set() : { _items: [], has: function(x) { return this._items.indexOf(x) >= 0; }, add: function(x) { this._items.push(x); } };

    function _choAttachToWs(ws, source) {
      if (!ws || _choAttachedWs.has(ws)) return;
      _choAttachedWs.add(ws);
      console.log('🔌 CHO: Scanner attaching to existing WS (' + source + ') readyState=' + ws.readyState);
      ws.addEventListener('message', function(event) {
        _choCheckPrescription(event.data);
      });
    }

    var _choScanInterval = setInterval(function() {
      _choScanCount++;
      try {
        // Scan 1: Check our tracked list (from constructor replacement)
        var tracked = window.__choTrackedWs || [];
        for (var i = 0; i < tracked.length; i++) {
          _choAttachToWs(tracked[i], 'tracked');
        }

        // Scan 2: Look for Socket.IO manager internals
        // socket.io-client stores transport.ws on the engine
        if (window.io && window.io.managers) {
          try {
            var mgrs = window.io.managers;
            for (var url in mgrs) {
              var mgr = mgrs[url];
              if (mgr && mgr.engine && mgr.engine.transport && mgr.engine.transport.ws) {
                _choAttachToWs(mgr.engine.transport.ws, 'io.managers');
              }
            }
          } catch(e) {}
        }

        // Scan 3: Check common global variable names for socket instances
        var names = ['socket', '_socket', 'ws', '_ws', 'webSocket', 'conn', 'connection'];
        for (var ni = 0; ni < names.length; ni++) {
          var obj = window[names[ni]];
          if (obj && obj instanceof (window.__OrigWebSocket || WebSocket)) {
            _choAttachToWs(obj, 'window.' + names[ni]);
          }
          // Also check if it's a Socket.IO socket with .io.engine.transport.ws
          if (obj && obj.io && obj.io.engine && obj.io.engine.transport && obj.io.engine.transport.ws) {
            _choAttachToWs(obj.io.engine.transport.ws, names[ni] + '.io.engine');
          }
        }

        // Scan 4: Search iframes for WebSocket references
        try {
          var frames = document.querySelectorAll('iframe');
          for (var fi = 0; fi < frames.length; fi++) {
            try {
              var fw = frames[fi].contentWindow;
              if (fw && fw.WebSocket) {
                var fnames = ['socket', '_socket', 'ws'];
                for (var fni = 0; fni < fnames.length; fni++) {
                  if (fw[fnames[fni]] && fw[fnames[fni]] instanceof (window.__OrigWebSocket || WebSocket)) {
                    _choAttachToWs(fw[fnames[fni]], 'iframe.' + fnames[fni]);
                  }
                }
              }
            } catch(e) {} // cross-origin frames will throw
          }
        } catch(e) {}
      } catch(e) {
        console.log('⚠️ CHO WS scanner error: ' + e);
      }

      // Log periodic scan status (every 10th scan = every 5 seconds)
      if (_choScanCount % 10 === 1) {
        var _choAttachedCount =
            (typeof _choAttachedWs.size === 'number')
                ? _choAttachedWs.size
                : ((_choAttachedWs._items && _choAttachedWs._items.length) || 0);
        console.log('🔍 CHO WS scanner: scan #' + _choScanCount + ' tracked=' + (window.__choTrackedWs || []).length + ' attached=' + _choAttachedCount);
      }

      // Stop scanning after 5 minutes (600 scans at 500ms)
      if (_choScanCount > 600) {
        clearInterval(_choScanInterval);
        console.log('🔍 CHO WS scanner: stopped after 5 min');
      }
    }, 500);
    console.log('✅ CHO: WebSocket scanner started (Layer B active)');
  }

  // ── Layer C: WebSocket.prototype.onmessage setter (belt-and-suspenders) ──
  // Try to patch the onmessage setter. If Android WebView supports it, great.
  // If not, Layers A+B are already handling it.
  if (!window.__choWsOnmsgPatched) {
    window.__choWsOnmsgPatched = true;
    try {
      var _wsMsgDesc = Object.getOwnPropertyDescriptor(WebSocket.prototype, 'onmessage');
      if (_wsMsgDesc && _wsMsgDesc.set) {
        var _origSet = _wsMsgDesc.set;
        var _origGet = _wsMsgDesc.get;
        Object.defineProperty(WebSocket.prototype, 'onmessage', {
          configurable: true,
          enumerable: true,
          get: _origGet,
          set: function(handler) {
            var ws = this;
            console.log('🔌 CHO: ws.onmessage setter intercepted');
            var wrapped = function(event) {
              _choCheckPrescription(event.data);
              if (handler) handler.call(ws, event);
            };
            _origSet.call(ws, wrapped);
          }
        });
        console.log('✅ CHO: WS.prototype.onmessage setter patched (Layer C active)');
      } else {
        console.log('⚠️ CHO: WS.prototype.onmessage descriptor not available (Layer C skipped)');
      }
    } catch(e) {
      console.log('⚠️ CHO: WS.onmessage setter patch failed: ' + e + ' (Layer C skipped)');
    }
  }

  console.log('✅ CHO: Section 4 complete (phase=' + phase + ')');

  // ── 5. Intercept window.open (catches prescription popups / new-tab PDFs) ──
  if (!window.__choWinOpenPatched) {
    window.__choWinOpenPatched = true;
    var _origWinOpen = window.open;
    window.open = function(url, target, features) {
      try {
        var u = String(url || '');
        var ul = u.toLowerCase();
        if (ul.includes('prescription') || ul.includes('getpdf') || ul.endsWith('.pdf')) {
          console.log('📋 CHO: window.open prescription → bridge: ' + u);
          if (window.CHOPrescriptionBridge) {
            window.CHOPrescriptionBridge.postMessage(JSON.stringify({pdfUrl: u, appointmentId: ''}));
          }
          return null;
        }
      } catch(e) {}
      return _origWinOpen ? _origWinOpen.call(window, url, target, features) : null;
    };
  }

  // ── 5B. Intercept history / form / anchor navigation to prescription URLs ──
  if (!window.__choNavHooksPatched) {
    window.__choNavHooksPatched = true;
    try {
      function _choBridgeUrl(url, source) {
        try {
          var u = String(url || '');
          var resolved = _choUnwrapViewerUrl(u) || u;
          if (_choPdfUrlOk(resolved)) {
            console.log('📋 CHO: ' + source + ' prescription → ' + resolved);
            if (window.CHOPrescriptionBridge) {
              window.CHOPrescriptionBridge.postMessage(JSON.stringify({pdfUrl: resolved, appointmentId: ''}));
            }
          }
        } catch(e) {}
      }

      var _origPushState = history.pushState;
      history.pushState = function(state, title, url) {
        _choBridgeUrl(url, 'history.pushState');
        return _origPushState.apply(history, arguments);
      };

      var _origReplaceState = history.replaceState;
      history.replaceState = function(state, title, url) {
        _choBridgeUrl(url, 'history.replaceState');
        return _origReplaceState.apply(history, arguments);
      };

      document.addEventListener('click', function(event) {
        try {
          var el = event.target;
          while (el && el.tagName !== 'A') el = el.parentElement;
          if (!el) return;
          _choBridgeUrl(el.href || el.getAttribute('href') || '', 'anchor.click');
        } catch(e) {}
      }, true);

      var _origSubmit = HTMLFormElement.prototype.submit;
      HTMLFormElement.prototype.submit = function() {
        try {
          _choBridgeUrl(this.action || '', 'form.submit');
        } catch(e) {}
        return _origSubmit.apply(this, arguments);
      };
    } catch(e) {
      console.log('⚠️ CHO: nav hooks failed: ' + e);
    }
  }

  // ── Helper: extract PDF URL from any response object ────────────────────
  // Scans all string values in a JSON object for a prescription PDF URL.
  // Also unwraps Google Docs viewer URLs: viewer?url=https://...getpdf/...
  function _choPdfFromData(data) {
    if (!data || typeof data !== 'object') return '';
    var keys = ['pdf_url','pdfUrl','file_url','fileUrl','prescription_url',
                'prescriptionUrl','pdfLink','pdf_link','docUrl','doc_url',
                'prescUrl','presc_url','url','link','viewerUrl','viewer_url'];
    for (var ki = 0; ki < keys.length; ki++) {
      var v = data[keys[ki]];
      if (v && typeof v === 'string') {
        var pdfUrl = _choUnwrapViewerUrl(v);
        if (pdfUrl) return pdfUrl;
      }
    }
    // Scan ALL string values as fallback
    for (var k in data) {
      if (typeof data[k] === 'string') {
        var pdfUrl = _choUnwrapViewerUrl(data[k]);
        if (pdfUrl) return pdfUrl;
      }
      if (data[k] && typeof data[k] === 'object') {
        var nested = _choPdfFromData(data[k]);
        if (nested) return nested;
      }
    }
    return '';
  }

  // Unwrap a Google Docs viewer URL to get the real PDF URL, or return the
  // URL itself if it already looks like a prescription PDF.
  function _choUnwrapViewerUrl(url) {
    if (!url || typeof url !== 'string') return '';
    var u = url.trim();
    // Google Docs viewer: viewer?url=https://...getpdf/...pdf
    if (u.includes('docs.google.com') || u.includes('viewerng') ||
        u.includes('viewer?url=') || u.includes('viewer?src=')) {
      try {
        var match = u.match(/[?&](?:url|src)=([^&]+)/);
        if (match) {
          var decoded = decodeURIComponent(match[1]);
          if (_choPdfUrlOk(decoded)) return decoded;
        }
      } catch(e) {}
      // Even if unwrap fails, log the viewer URL itself
      if (_choPdfUrlOk(u)) return u;
      return '';
    }
    if (_choPdfUrlOk(u)) return u;
    return '';
  }

  function _choPdfFromText(text) {
    if (!text || typeof text !== 'string') return '';
    try {
      var docsViewer = text.match(/https?:\\/\\/docs\\.google\\.com\\/viewer[^\\s"'<>]+/i);
      if (docsViewer && docsViewer[0]) {
        var unwrappedViewer = _choUnwrapViewerUrl(docsViewer[0]);
        if (unwrappedViewer) return unwrappedViewer;
      }
      var directPdf = text.match(/https?:\\/\\/[^\\s"'<>]+(?:getpdf|prescription)[^\\s"'<>]*\\.pdf/ig);
      if (directPdf && directPdf.length) {
        var direct = _choUnwrapViewerUrl(directPdf[0]);
        if (direct) return direct;
      }
      var relativePdf = text.match(/\\/prescription_api\\/getpdf\\/[^\\s"'<>]+\\.pdf/ig);
      if (relativePdf && relativePdf.length) {
        return 'https://dhanvantari.net.in' + relativePdf[0];
      }
    } catch(e) {}
    return '';
  }

  function _choPdfUrlOk(url) {
    if (!url || typeof url !== 'string') return false;
    if (!url.startsWith('http') && !url.startsWith('data:')) return false;
    var l = url.toLowerCase();
    return l.includes('getpdf') || l.includes('prescription') ||
           l.endsWith('.pdf') || l.includes('/pdf/') ||
           l.includes('presc') || l.includes('generate-prescription');
  }

  // ── 6 + 7. Universal XHR + fetch response scanner ─────────────────────────
  // KEY INSIGHT: tele_back/ uses Socket.IO long-POLLING (XHR to
  // /socket.io/?transport=polling), NOT WebSocket.  Every socket message the
  // doctor sends (including the prescription PDF) arrives as plain text in an
  // XHR response body — e.g.:
  //   97:42["message",{"type":"chat","message_type":"file","file_url":"data:…"}]
  // Scanning ONLY prescription-specific URLs misses these entirely.
  // We now scan ALL responses whose body contains a Socket.IO frame ("42[").
  if (!window.__choUniversalRespScanner) {
    window.__choUniversalRespScanner = true;
    var _choSeenRespKeys = {};

    // Shared helper: scan any response body for Socket.IO frames or prescription data.
    window._choScanAnyBody = function(body, srcUrl) {
      if (!body || typeof body !== 'string' || body.length < 5) return;
      // Quick guard: only process if body has something relevant.
      var hasFrame   = body.indexOf('42[') >= 0 || body.indexOf('42{') >= 0;
      var hasPrDesc  = body.indexOf('getpdf') >= 0 ||
                       body.indexOf('prescription') >= 0 ||
                       body.indexOf('file_url') >= 0 ||
                       body.indexOf('.pdf') >= 0;
      if (!hasFrame && !hasPrDesc) return;
      // De-duplicate (Socket.IO polls produce many identical payloads).
      var key = (srcUrl || '').substring(0, 50) + '|' + body.substring(0, 80);
      if (_choSeenRespKeys[key]) return;
      _choSeenRespKeys[key] = 1;
      console.log('📡 CHO scan: relevant body from ' + String(srcUrl || '?').substring(0, 100));
      // 1. Full body as-is (may be a single frame or JSON blob)
      _choCheckPrescription(body);
      // 2. Split Socket.IO packet batches: frames separated by '\x1e' (RS char)
      if (body.indexOf('\x1e') >= 0) {
        body.split('\x1e').forEach(function(part) {
          if (part.indexOf('42') === 0) _choCheckPrescription(part);
        });
      }
      // 3. Socket.IO v2 length-prefixed framing: "NNN:42[...]" — strip prefix.
      try {
        var si = 0;
        while (si < body.length) {
          var fi = body.indexOf(':42[', si);
          if (fi < 0) break;
          _choCheckPrescription(body.substring(fi + 1));
          si = fi + 4;
        }
      } catch(e) {}
      // 4. Pure JSON blob (prescription REST endpoint returning pdfUrl)
      try {
        var j = JSON.parse(body);
        if (j && typeof j === 'object') {
          var pdfUrl = _choPdfFromData(j);
          if (pdfUrl && window.CHOPrescriptionBridge) {
            console.log('📋 CHO: PDF URL from JSON resp → ' + pdfUrl);
            window.CHOPrescriptionBridge.postMessage(JSON.stringify({pdfUrl: pdfUrl, appointmentId: ''}));
          }
        }
      } catch(e) {}
    };

    // ── 6. Wrap XHR: scan ALL responses ──────────────────────────────────────
    if (!window.__choXhrRespPatched) {
      window.__choXhrRespPatched = true;
      var _origXhrOpen3 = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url) {
        this.__choXhrRespUrl = String(url || '');
        return _origXhrOpen3.apply(this, arguments);
      };
      var _origXhrSend3 = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function() {
        var self3 = this;
        self3.addEventListener('load', function() {
          try {
            window._choScanAnyBody(self3.responseText || '', self3.__choXhrRespUrl || '');
          } catch(e) {}
        });
        return _origXhrSend3.apply(this, arguments);
      };
      console.log('✅ CHO: Universal XHR response scanner active (Section 6)');
    }

    // ── 7. Wrap fetch: scan ALL responses ─────────────────────────────────────
    if (!window.__choFetchRespPatched) {
      window.__choFetchRespPatched = true;
      var _baseFetch = window.fetch.bind(window);
      window.fetch = function(input, init) {
        var reqUrl = (typeof input === 'string') ? input : ((input && input.url) || '');
        var result = _baseFetch(input, init);
        try {
          result = result.then(function(resp) {
            try {
              resp.clone().text().then(function(text) {
                window._choScanAnyBody(text, reqUrl);
              }).catch(function(){});
            } catch(e) {}
            return resp;
          });
        } catch(e) {}
        return result;
      };
      console.log('✅ CHO: Universal fetch response scanner active (Section 7)');
    }
  }

  // ── 8. MutationObserver: catch <iframe src="...getpdf..."> injections ─────
  // If the page inserts a prescription iframe into the DOM (without a top-level
  // navigation), onNavigationRequest won't fire.  We catch it here, remove the
  // iframe, and open Flutter's PDF overlay instead.
  if (!window.__choMutObsPatched) {
    window.__choMutObsPatched = true;
    try {
      var _checkPrescriptionNode = function(node) {
        if (!node || node.nodeType !== 1) return;
        var tag = (node.tagName || '').toUpperCase();
        if (tag !== 'IFRAME' && tag !== 'FRAME') return;
        var src = node.getAttribute('src') || '';
        if (!src) return;
        var sl = src.toLowerCase();
        var isPrescript = sl.includes('getpdf') || sl.includes('prescription') || sl.endsWith('.pdf');
        var realUrl = src;
        if (!isPrescript) {
          // Check viewer?url= or ?src= wrapper pattern
          try {
            var parsed = new URL(src, location.href);
            var wrapped = parsed.searchParams.get('url') || parsed.searchParams.get('src') || '';
            var wl = wrapped.toLowerCase();
            if (wl.includes('getpdf') || wl.includes('prescription') || wl.endsWith('.pdf')) {
              isPrescript = true;
              realUrl = wrapped;
            }
          } catch(e2) {}
        }
        if (isPrescript) {
          console.log('📋 CHO: MutObs prescription iframe → ' + realUrl);
          try { node.remove(); } catch(e) {}
          if (window.CHOPrescriptionBridge) {
            window.CHOPrescriptionBridge.postMessage(JSON.stringify({pdfUrl: realUrl, appointmentId: ''}));
          }
        }
      };
      var _prescObs = new MutationObserver(function(mutations) {
        mutations.forEach(function(m) {
          m.addedNodes.forEach(function(n) {
            _checkPrescriptionNode(n);
            if (n.querySelectorAll) {
              try { n.querySelectorAll('iframe,frame').forEach(_checkPrescriptionNode); } catch(e) {}
            }
          });
          if (m.type === 'attributes' && m.attributeName === 'src') {
            _checkPrescriptionNode(m.target);
          }
        });
      });
      var _obsRoot = document.documentElement || document.body;
      if (_obsRoot) {
        _prescObs.observe(_obsRoot, {childList: true, subtree: true, attributes: true, attributeFilter: ['src']});
      }
    } catch(e) { console.log('⚠️ CHO: MutObs patch failed: ' + e); }
  }

  // ── 8b. /pres/ same-origin iframe injection ─────────────────────────────
  // KEY: tele_back/ embeds /pres/ in a same-origin iframe.  The prescription
  // URL is generated INSIDE /pres/ (index-BCiis0Um.js) and loaded via a
  // Google Docs Viewer iframe: docs.google.com/viewer?url=getpdf/...
  // Our window.* patches don't reach the iframe's window — we must inject
  // into it separately.  Since /pres/ is same-origin, this is allowed.
  if (!window.__choPresIframeWatcher) {
    window.__choPresIframeWatcher = true;
    var _choInjectedFrames = [];

    function _choInjectIntoFrame(ifr) {
      try {
        if (!ifr || _choInjectedFrames.indexOf(ifr) >= 0) return;
        var fw = ifr.contentWindow;
        if (!fw || !fw.document) return;
        _choInjectedFrames.push(ifr);

        // Forward Flutter bridge into the iframe's window so its JS can call it.
        if (window.CHOPrescriptionBridge && !fw.CHOPrescriptionBridge) {
          fw.CHOPrescriptionBridge = window.CHOPrescriptionBridge;
        }

        // ── PRIORITY 1: Hook console.log inside /pres/ iframe ──────────────
        // index-BCiis0Um.js logs exactly:
        //   "PDF preview loaded using Google Docs Viewer: {url}"
        // This is the most reliable signal — catch it directly.
        if (!fw.__choPdfLogHooked) {
          fw.__choPdfLogHooked = true;
          var _origFwLog = fw.console.log.bind(fw.console);
          fw.console.log = function() {
            try {
              var args = Array.prototype.slice.call(arguments);
              var msg = args.join(' ');
              if (msg.indexOf('PDF preview loaded using Google Docs Viewer') >= 0) {
                // Extract the URL from the log message
                var urlMatch = msg.match(/https?:\\/\\/[\\S]+\\.pdf/i);
                if (!urlMatch) urlMatch = msg.match(/https?:\\/\\/[\\S]+getpdf[\\S]*/i);
                var pdfUrl = urlMatch ? urlMatch[0].replace(/['"<>]+\$/, '') : '';
                if (pdfUrl) {
                  console.log('📋 CHO pres-iframe console.log → ' + pdfUrl);
                  var bridge = fw.CHOPrescriptionBridge || window.CHOPrescriptionBridge;
                  if (bridge) bridge.postMessage(JSON.stringify({pdfUrl: pdfUrl, appointmentId: ''}));
                }
              }
              // Also catch uploadResponse / "PDF uploaded" lines for early detection
              if (msg.indexOf('Upload Response') >= 0 || msg.indexOf('PDF uploaded') >= 0) {
                console.log('📋 CHO pres-iframe: upload event → polling for PDF in 2s');
                // Trigger a DOM scan 2 seconds later when PDF URL will be set
                setTimeout(function() {
                  try {
                    fw.document.querySelectorAll('iframe[src]').forEach(function(fi) {
                      _choCheckIframeSrc(fi.getAttribute('src') || '');
                    });
                    var html = fw.document.documentElement ? fw.document.documentElement.innerHTML : '';
                    if (html && html.indexOf('docs.google.com/viewer') >= 0) {
                      var pdfInHtml = _choPdfFromText(html);
                      if (pdfInHtml) {
                        var bridge2 = fw.CHOPrescriptionBridge || window.CHOPrescriptionBridge;
                        if (bridge2) bridge2.postMessage(JSON.stringify({pdfUrl: pdfInHtml, appointmentId: ''}));
                      }
                    }
                  } catch(e) {}
                }, 2000);
              }
            } catch(e) {}
            return _origFwLog.apply(fw.console, arguments);
          };
          console.log('✅ CHO: console.log hooked inside /pres/ iframe');
        }

        // Helper: check a src string for prescription PDF and send to bridge.
        function _choCheckIframeSrc(src) {
          if (!src) return;
          var sl = src.toLowerCase();
          // Case 1: Google Docs Viewer wrapping the prescription PDF URL
          if (sl.indexOf('docs.google.com') >= 0 && (sl.indexOf('getpdf') >= 0 || sl.indexOf('prescription') >= 0)) {
            try {
              var p = new URL(src);
              var inner = p.searchParams.get('url') || p.searchParams.get('src') || '';
              var pdfUrl = (inner && (inner.toLowerCase().indexOf('getpdf') >= 0 || inner.endsWith('.pdf'))) ? inner : src;
              console.log('📋 CHO pres-iframe: GDV iframe detected → ' + pdfUrl.substring(0, 150));
              var bridge = fw.CHOPrescriptionBridge || window.CHOPrescriptionBridge;
              if (bridge) bridge.postMessage(JSON.stringify({pdfUrl: pdfUrl, appointmentId: ''}));
            } catch(e) {}
            return;
          }
          // Case 2: Direct getpdf / .pdf iframe src
          if (sl.indexOf('getpdf') >= 0 || (sl.indexOf('prescription') >= 0 && sl.endsWith('.pdf'))) {
            console.log('📋 CHO pres-iframe: direct PDF iframe → ' + src.substring(0, 150));
            var bridge2 = fw.CHOPrescriptionBridge || window.CHOPrescriptionBridge;
            if (bridge2) bridge2.postMessage(JSON.stringify({pdfUrl: src, appointmentId: ''}));
          }
        }

        // Observe /pres/ DOM for iframe elements being added (GDV loads as iframe).
        try {
          var presObs = new (fw.MutationObserver || window.MutationObserver)(function(muts) {
            muts.forEach(function(m) {
              m.addedNodes.forEach(function(n) {
                if (!n || n.nodeType !== 1) return;
                var t = (n.tagName || '').toUpperCase();
                if (t === 'IFRAME' || t === 'FRAME' || t === 'EMBED' || t === 'OBJECT') {
                  _choCheckIframeSrc(n.getAttribute('src') || n.getAttribute('data') || '');
                }
                if (n.querySelectorAll) {
                  try {
                    n.querySelectorAll('iframe,frame,embed,object').forEach(function(fi) {
                      _choCheckIframeSrc(fi.getAttribute('src') || fi.getAttribute('data') || '');
                    });
                  } catch(e) {}
                }
              });
              if (m.type === 'attributes') {
                _choCheckIframeSrc(m.target.getAttribute('src') || m.target.getAttribute('data') || '');
              }
            });
          });
          var presRoot = fw.document.documentElement || fw.document.body;
          if (presRoot) {
            presObs.observe(presRoot, {childList: true, subtree: true, attributes: true, attributeFilter: ['src','data']});
            console.log('✅ CHO: MutObs injected into same-origin iframe');
          }
        } catch(e) { console.log('⚠️ CHO presObs error: ' + e); }

        // Scan DOM inside /pres/ RIGHT NOW in case prescription already rendered.
        try {
          fw.document.querySelectorAll('iframe[src],frame[src],embed[src]').forEach(function(fi) {
            _choCheckIframeSrc(fi.getAttribute('src') || '');
          });
          // Also scan raw HTML for any getpdf URL that may be embedded in text.
          var html = fw.document.documentElement ? fw.document.documentElement.innerHTML : '';
          if (html && (html.indexOf('getpdf') >= 0 || html.indexOf('docs.google.com/viewer') >= 0)) {
            var pdfFound = _choPdfFromText(html);
            if (pdfFound) {
              console.log('📋 CHO pres-iframe: PDF URL in DOM HTML → ' + pdfFound.substring(0,150));
              var bridge3 = fw.CHOPrescriptionBridge || window.CHOPrescriptionBridge;
              if (bridge3) bridge3.postMessage(JSON.stringify({pdfUrl: pdfFound, appointmentId: ''}));
            }
          }
        } catch(e) {}
      } catch(e) { console.log('⚠️ CHO _choInjectIntoFrame error: ' + e); }
    }

    // Run injection for a frame element, now and on its load event.
    function _choWatchFrame(f) {
      try {
        var src = f.getAttribute('src') || '';
        // Only inject into same-origin frames (blank src = same-origin, or dhanvantari.net.in).
        if (src.indexOf('http') === 0 && src.indexOf('dhanvantari.net.in') < 0) return;
        f.addEventListener('load', function() { _choInjectIntoFrame(f); });
        _choInjectIntoFrame(f); // try immediately (if already loaded)
      } catch(e) {}
    }

    // Watch tele_back/'s own DOM for new iframes being added (e.g., /pres/ lazy-loaded).
    try {
      var _choFrameObs = new MutationObserver(function(muts) {
        muts.forEach(function(m) {
          m.addedNodes.forEach(function(n) {
            if (!n || n.nodeType !== 1) return;
            var t = (n.tagName || '').toUpperCase();
            if (t === 'IFRAME' || t === 'FRAME') _choWatchFrame(n);
            if (n.querySelectorAll) {
              try { n.querySelectorAll('iframe,frame').forEach(_choWatchFrame); } catch(e) {}
            }
          });
        });
      });
      var _choFObsRoot = document.documentElement || document.body;
      if (_choFObsRoot) _choFrameObs.observe(_choFObsRoot, {childList: true, subtree: true});
    } catch(e) {}

    // Inject into already-present same-origin iframes immediately.
    try {
      document.querySelectorAll('iframe,frame').forEach(_choWatchFrame);
    } catch(e) {}

    console.log('✅ CHO: /pres/ iframe watcher active (Section 8b)');
  }

  // ── 9. Periodic DOM scan for late viewer/getpdf URLs ──────────────────────
  // Also scans inside same-origin iframes so we catch /pres/ prescription URLs.
  if (!window.__choDomScanStarted) {
    window.__choDomScanStarted = true;
    var _choDomScanCount = 0;
    var _choLastDomPdf = '';
    var _choDomScan = setInterval(function() {
      _choDomScanCount++;
      try {
        var candidates = [];
        try { candidates.push(String(location.href || '')); } catch(e) {}
        try {
          var html = document.documentElement ? document.documentElement.innerHTML : '';
          if (html) candidates.push(html.substring(0, 250000));
        } catch(e) {}
        try {
          var anchors = document.querySelectorAll('a[href], iframe[src], frame[src], embed[src], object[data]');
          for (var i = 0; i < anchors.length && i < 200; i++) {
            var n = anchors[i];
            candidates.push(
              n.getAttribute('href') ||
              n.getAttribute('src') ||
              n.getAttribute('data') ||
              ''
            );
          }
        } catch(e) {}

        // Also scan same-origin iframes (catches /pres/ prescription URLs).
        try {
          document.querySelectorAll('iframe,frame').forEach(function(f) {
            try {
              var fw = f.contentWindow;
              if (!fw || !fw.document) return;
              var fhtml = fw.document.documentElement ? fw.document.documentElement.innerHTML : '';
              if (fhtml) candidates.push(fhtml.substring(0, 100000));
              fw.document.querySelectorAll('iframe[src],embed[src]').forEach(function(fi) {
                candidates.push(fi.getAttribute('src') || '');
              });
            } catch(e) {} // cross-origin will throw — ignore
          });
        } catch(e) {}

        for (var ci = 0; ci < candidates.length; ci++) {
          var found = _choPdfFromText(String(candidates[ci] || ''));
          if (found && found !== _choLastDomPdf) {
            _choLastDomPdf = found;
            console.log('📋 CHO: DOM scan pdfUrl=' + found);
            if (window.CHOPrescriptionBridge) {
              window.CHOPrescriptionBridge.postMessage(JSON.stringify({pdfUrl: found, appointmentId: ''}));
            }
            break;
          }
        }
      } catch(e) {}

      if (_choDomScanCount > 180) {
        clearInterval(_choDomScan);
      }
    }, 1000);
  }

  // ── 10. Firestore long-poll response scanner ─────────────────────────────
  // The web app uses Firestore (healthstack-6bc78) for real-time updates.
  // When the doctor saves a prescription, the Firestore update may contain
  // the PDF URL or a prescription_status field.  We scan Firestore
  // channel responses (XHR to firestore.googleapis.com/.../Listen/channel)
  // for prescription data and trigger the bridge.
  if (!window.__choFirestoreScanner) {
    window.__choFirestoreScanner = true;
    var _origXhrOpenFS = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function(method, url) {
      this.__choFsUrl = String(url || '');
      return _origXhrOpenFS.apply(this, arguments);
    };
    var _origXhrSendFS = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function() {
      var self4 = this;
      if (self4.__choFsUrl && self4.__choFsUrl.indexOf('firestore.googleapis.com') >= 0) {
        self4.addEventListener('load', function() {
          try {
            var resp = self4.responseText || '';
            if (resp.length < 10) return;
            // Firestore responses contain JSON arrays with document changes.
            // Look for prescription-related field changes.
            var hasPrescData = resp.indexOf('prescription') >= 0 ||
                               resp.indexOf('getpdf') >= 0 ||
                               resp.indexOf('.pdf') >= 0 ||
                               resp.indexOf('pdf_url') >= 0 ||
                               resp.indexOf('pdfUrl') >= 0 ||
                               resp.indexOf('prescription_status') >= 0;
            if (!hasPrescData) return;
            console.log('🔥 CHO Firestore: prescription-related data detected');
            // Extract PDF URL from Firestore response
            var pdfMatch = resp.match(/https?:\\/\\/[^\\s"'\\\\]+(?:getpdf|prescription)[^\\s"'\\\\]*\\.pdf/i);
            if (pdfMatch) {
              var pdfUrl = pdfMatch[0];
              console.log('📋 CHO Firestore: PDF URL found → ' + pdfUrl);
              if (window.CHOPrescriptionBridge) {
                window.CHOPrescriptionBridge.postMessage(JSON.stringify({pdfUrl: pdfUrl, appointmentId: ''}));
              }
              return;
            }
            // Also check for relative paths
            var relMatch = resp.match(/\\/prescription_api\\/getpdf\\/[^\\s"'\\\\]+\\.pdf/i);
            if (relMatch) {
              var relUrl = 'https://dhanvantari.net.in' + relMatch[0];
              console.log('📋 CHO Firestore: relative PDF URL found → ' + relUrl);
              if (window.CHOPrescriptionBridge) {
                window.CHOPrescriptionBridge.postMessage(JSON.stringify({pdfUrl: relUrl, appointmentId: ''}));
              }
              return;
            }
            // If we see prescription_status changed but no URL, trigger a REST poll
            if (resp.indexOf('prescription_status') >= 0 ||
                (resp.indexOf('prescription') >= 0 && resp.indexOf('completed') >= 0)) {
              console.log('📋 CHO Firestore: prescription status change detected → notifying bridge for REST poll');
              if (window.CHOPrescriptionBridge) {
                window.CHOPrescriptionBridge.postMessage(JSON.stringify({pdfUrl: '', appointmentId: '', firestoreTrigger: true}));
              }
            }
          } catch(e) {
            console.log('⚠️ CHO Firestore scanner error: ' + e);
          }
        });
      }
      return _origXhrSendFS.apply(this, arguments);
    };
    console.log('✅ CHO: Firestore response scanner active (Section 10)');
  }

  console.log('✅ CHO auth [' + phase + ']: token=' + (token ? token.length + 'ch' : 'EMPTY') + ' csrf=' + (getCsrf() ? 'found' : 'NOT FOUND'));
})();
""";

    _controller!.runJavaScript(js).catchError((e) {
      debugPrint('⚠️ VideoWebView: JS injection error [$phase]: $e');
    });
  }

  // ══════════════════════════════════════════════════════════
  // SILENT RE-LOGIN
  // ══════════════════════════════════════════════════════════

  /// Called when the telemed WebView is redirected to the Django login page,
  /// which means the web session (cookie) expired.
  ///
  /// Instead of showing a login form INSIDE the WebView (or just closing the
  /// call), we silently re-authenticate using the CHO app's own saved
  /// credentials — the exact same flow as login_page.dart — then push the
  /// fresh session cookies into the WebView cookie store and reload the page.
  ///
  /// If no saved credentials exist (remember_me was off) we fall back to
  /// popping back to the Flutter app so the user can log in normally.
  Future<void> _silentReLogin() async {
    if (_reLoginInProgress) return; // guard against duplicate events
    _reLoginInProgress = true;
    debugPrint('🔄 SilentReLogin: starting...');

    try {
      final prefs = await SharedPreferences.getInstance();
      final remember = prefs.getBool('remember_me') ?? false;
      final email    = prefs.getString('saved_email') ?? '';
      final password = prefs.getString('saved_password') ?? '';

      if (!remember || email.isEmpty || password.isEmpty) {
        // No saved credentials — the user must log in manually.
        debugPrint('⚠️ SilentReLogin: no saved credentials → popping to login');
        if (mounted) Navigator.pop(context);
        return;
      }

      debugPrint('🔄 SilentReLogin: re-authenticating as $email...');

      // Re-use ApiService.login() — this runs the full session-init →
      // encrypt → login flow, stores a fresh auth_token + cookies in prefs,
      // and updates ApiService's internal state.
      final result = await ApiService.login(email, password);

      if (!result.success) {
        debugPrint('❌ SilentReLogin: re-auth failed: ${result.message}');
        if (mounted) Navigator.pop(context);
        return;
      }

      debugPrint('✅ SilentReLogin: re-auth OK — refreshing WebView session');

      // Read the fresh cookies that ApiService just stored.
      final freshCookies = prefs.getString('cookies') ?? '';
      if (freshCookies.isNotEmpty) {
        await _injectCookies(freshCookies);
        debugPrint('🍪 SilentReLogin: fresh cookies injected into WebView');
      }

      // Update the in-memory auth token so JS injection also uses the new one.
      _authToken = prefs.getString('auth_token');

      // Reload the telemed page with the refreshed session.
      if (mounted) {
        setState(() { _isLoading = true; _hasError = false; });
        _controller?.reload();
      }
    } catch (e) {
      debugPrint('❌ SilentReLogin: error: $e');
      if (mounted) Navigator.pop(context);
    } finally {
      _reLoginInProgress = false;
    }
  }

  void _schedulePostTelemedRedirectFallback(String url) {
    _postTelemedRedirectTimer?.cancel();
    _postTelemedRedirectTimer = Timer(const Duration(seconds: 20), () {
      if (!mounted || _prescriptionFound) return;
      debugPrint(
          '⌛ VideoWebView: no prescription detected after redirect → popping ($url)');
      Navigator.pop(context);
    });
  }

  void _cancelPostTelemedRedirectFallback() {
    _postTelemedRedirectTimer?.cancel();
    _postTelemedRedirectTimer = null;
  }

  @override
  void dispose() {
    _postTelemedRedirectTimer?.cancel();
    _postTelemedRedirectTimer = null;
    _prescriptionPollTimer?.cancel();
    _prescriptionPollTimer = null;
    VideoCallService.instance.removeChatMessageListener();
    VideoCallService.instance.disconnect();
    // Restore normal UI (status bar + nav bar) when leaving the call.
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values, // show all overlays
    );
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
    _wakeChannel.invokeMethod('release').catchError((_) {});
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════
  // PRESCRIPTION DETECTION  (socket-based, matching reference app)
  // ══════════════════════════════════════════════════════════

  // ══════════════════════════════════════════════════════════
  // PRESCRIPTION EVENT HANDLER
  // ══════════════════════════════════════════════════════════

  /// Called when the JavaScript bridge receives a prescription WebSocket event.
  /// [message] is a JSON string: { appointmentId, pdfUrl, fileName, raw }
  ///
  /// pdfUrl can be:
  ///   • "https://..." → direct URL, open in overlay WebView
  ///   • "data:application/pdf;base64,..." → base64 PDF, load directly in WebView
  ///   • "" → no URL, fall back to REST API fetch using appointmentId
  void _onPrescriptionEvent(String message) {
    if (_prescriptionFound) return; // already showing prescription
    try {
      final json = _parseJson(message);
      final pdfUrl = (json['pdfUrl'] ?? '').toString().trim();
      final fileName = (json['fileName'] ?? 'prescription.pdf').toString().trim();
      final apptId = (json['appointmentId'] ?? widget.appointmentId.toString()).toString().trim();
      final firestoreTrigger = json['firestoreTrigger'] == true || json['firestoreTrigger'] == 'true';

      // Case 0: Firestore status-change trigger (no PDF URL, just a hint to poll REST)
      if (firestoreTrigger && pdfUrl.isEmpty) {
        debugPrint('📋 PrescriptionBridge: Firestore trigger → immediate REST poll');
        _fetchAndShowPrescription(apptId.isNotEmpty ? apptId : widget.appointmentId.toString());
        return;
      }

      // Case 1: direct HTTPS URL
      if (pdfUrl.isNotEmpty && pdfUrl.startsWith('http')) {
        debugPrint('📋 PrescriptionBridge: HTTPS PDF URL → $pdfUrl');
        _prescriptionFound = true;
        _openPdfOverlay(pdfUrl, fileName: fileName);
        return;
      }

      // Case 2: base64 data URI ("data:application/pdf;base64,...")
      // Android WebView supports loading data: URIs directly via loadRequest.
      if (pdfUrl.isNotEmpty && pdfUrl.startsWith('data:')) {
        debugPrint('📋 PrescriptionBridge: base64 PDF received (${pdfUrl.length} chars)');
        _prescriptionFound = true;
        _openPdfOverlay(pdfUrl, fileName: fileName);
        return;
      }

      // Case 3: no URL in the message → fall back to REST API
      final id = apptId.isNotEmpty ? apptId : widget.appointmentId.toString();
      debugPrint('📋 PrescriptionBridge: no PDF in WS msg → fetching via API apptId=$id');
      _fetchAndShowPrescription(id);
    } catch (e) {
      debugPrint('⚠️ PrescriptionBridge: parse error: $e  raw="$message"');
    }
  }

  /// Fetch prescription for [prescriptionId] (appointmentId) using Flutter's HTTP client.
  ///
  /// The server URL format is: /prescription_api/getpdf/{ABHA_ID}/{TIMESTAMP}.pdf
  /// We don't know the timestamp, so we use the JSON list endpoint instead
  /// which returns the full PDF URL.
  /// Fetch prescription using the CORRECT API endpoint.
  /// This is the SAME endpoint the /telemed/ web app uses internally:
  ///   GET /appointment/api/appointments/{appointmentId}
  /// Response contains: { pres_link: "https://...getpdf/...", ... }
  Future<void> _fetchAndShowPrescription(String appointmentId) async {
    if (_prescriptionFound) return;
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('auth_token') ?? '';
    final cookies = prefs.getString('cookies') ?? '';

    // Helper: make an authenticated GET and return the body or null.
    Future<String?> authGet(String url) async {
      try {
        final uri = Uri.parse(url);
        debugPrint('📋 PrescriptionPoll: GET $uri');
        final client = HttpClient();
        client.badCertificateCallback = (_, __, ___) => true;
        final request = await client.getUrl(uri);
        if (token.isNotEmpty) request.headers.set('Authorization', 'Bearer $token');
        request.headers.set('Accept', 'application/json');
        if (cookies.isNotEmpty) request.headers.set('Cookie', cookies);
        final response = await request.close().timeout(const Duration(seconds: 10));
        if (response.statusCode == 200 || response.statusCode == 201) {
          return await response.transform(const Utf8Decoder()).join();
        }
        debugPrint('📋 PrescriptionPoll: GET $uri → ${response.statusCode}');
        response.drain<void>();
        return null;
      } catch (e) {
        debugPrint('📋 PrescriptionPoll: error: $e');
        return null;
      }
    }

    // ── PRIMARY: Same endpoint the /telemed/ web app uses ───────────────────
    // The React app's _n() function calls:
    //   axios.get(`${BASE}/appointment/api/appointments/${appointmentId}`)
    // and reads response.data.pres_link
    final primaryUrl =
        'https://dhanvantari.net.in/appointment/api/appointments/$appointmentId';
    final body = await authGet(primaryUrl);
    if (body != null && body.isNotEmpty) {
      try {
        final data = jsonDecode(body);
        if (data is Map<String, dynamic>) {
          // The web app reads: response.data.pres_link
          final presLink = (data['pres_link'] ?? data['presLink'] ??
              data['pdf_url'] ?? data['pdfUrl'] ?? data['prescription_url'] ??
              data['prescriptionUrl'] ?? '')
              .toString()
              .trim();
          if (presLink.isNotEmpty) {
            debugPrint('📋 PrescriptionPoll: ✅ pres_link found → $presLink');
            _prescriptionFound = true;
            if (mounted) _openPdfOverlay(presLink);
            return;
          }
          debugPrint('📋 PrescriptionPoll: appointment found but pres_link is empty (doctor hasn\'t saved yet)');
          // Also check nested structures
          final nested = data['prescription'] ?? data['data'];
          if (nested is Map<String, dynamic>) {
            final nestedLink = (nested['pres_link'] ?? nested['pdf_url'] ??
                nested['presLink'] ?? nested['pdfUrl'] ?? '')
                .toString()
                .trim();
            if (nestedLink.isNotEmpty) {
              debugPrint('📋 PrescriptionPoll: ✅ nested pres_link → $nestedLink');
              _prescriptionFound = true;
              if (mounted) _openPdfOverlay(nestedLink);
              return;
            }
          }
        }
      } catch (e) {
        debugPrint('📋 PrescriptionPoll: JSON parse error: $e');
      }
    }

    debugPrint('📋 PrescriptionPoll: no pres_link yet for appointmentId=$appointmentId');
  }

  /// Safe JSON → Map helper.
  Map<String, dynamic> _parseJson(String s) {
    try {
      final decoded = jsonDecode(s);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return {};
  }

  // ── PDF URL extraction helpers ────────────────────────────────────────────

  /// Recursively search [data] for any key that looks like a prescription PDF URL.
  String? _extractPdfUrl(Map<String, dynamic> data) {
    for (final key in [
      'pdf_url', 'pdfUrl', 'file_url', 'fileUrl',
      'prescription_url', 'prescriptionUrl', 'prescription_pdf_url',
      'prescriptionPdfUrl', 'document_url', 'documentUrl',
      'pdfLink', 'pdf_link', 'docUrl', 'doc_url', 'prescUrl', 'presc_url',
    ]) {
      final v = data[key];
      if (v is String && v.isNotEmpty) {
        final unwrapped = _unwrapViewerUrl(v);
        if (unwrapped.startsWith('http') && _looksLikePdfUrl(unwrapped)) {
          return unwrapped;
        }
      }
    }
    final urlVal = data['url'];
    if (urlVal is String && urlVal.isNotEmpty) {
      final unwrapped = _unwrapViewerUrl(urlVal);
      if (unwrapped.startsWith('http') && _looksLikePdfUrl(unwrapped)) return unwrapped;
    }
    for (final entry in data.entries) {
      final v = entry.value;
      if (v is String && v.isNotEmpty) {
        final unwrapped = _unwrapViewerUrl(v);
        if (unwrapped.startsWith('http') && _looksLikePdfUrl(unwrapped)) return unwrapped;
      }
    }
    for (final mapKey in ['prescription', 'data', 'result', 'response', 'details']) {
      final nested = data[mapKey];
      if (nested is Map<String, dynamic>) {
        final r = _extractPdfUrl(nested);
        if (r != null) return r;
      }
    }
    for (final entry in data.entries) {
      if (entry.value is Map<String, dynamic>) {
        final r = _extractPdfUrl(entry.value as Map<String, dynamic>);
        if (r != null) return r;
      }
    }
    return null;
  }

  /// Unwrap Google Docs viewer URL to get the actual PDF URL.
  String _unwrapViewerUrl(String url) {
    if (url.contains('docs.google.com') || url.contains('viewerng') ||
        url.contains('viewer?url=') || url.contains('viewer?src=')) {
      final match = RegExp(r'[?&](?:url|src)=([^&]+)').firstMatch(url);
      if (match != null) {
        try {
          final decoded = Uri.decodeComponent(match.group(1)!);
          if (_looksLikePdfUrl(decoded)) return decoded;
        } catch (_) {}
      }
    }
    return url;
  }

  /// Returns true if [url] looks like a prescription PDF link.
  bool _looksLikePdfUrl(String url) {
    final l = url.toLowerCase();
    return l.contains('getpdf') || l.contains('prescription') ||
        l.contains('.pdf') || l.contains('/pdf/') ||
        l.contains('generate-prescription') || l.contains('presc');
  }

  /// Extract a PDF URL from a text/HTML body string.
  String? _extractPdfUrlFromText(String text) {
    if (text.isEmpty) return null;
    final absolute = RegExp(
      "https?://[^\\s\"'<>]+(?:getpdf|prescription)[^\\s\"'<>]*\\.pdf",
      caseSensitive: false,
    ).firstMatch(text);
    if (absolute != null) return _unwrapViewerUrl(absolute.group(0)!);
    final relative = RegExp(
      "/(?:prescription_api/)?getpdf/[^\\s\"'<>]+\\.pdf",
      caseSensitive: false,
    ).firstMatch(text);
    if (relative != null) {
      final path = relative.group(0)!;
      return path.startsWith('http')
          ? _unwrapViewerUrl(path)
          : 'https://dhanvantari.net.in$path';
    }
    final genericPdf = RegExp(
      "https?://[^\\s\"'<>]+\\.pdf",
      caseSensitive: false,
    ).firstMatch(text);
    if (genericPdf != null) return _unwrapViewerUrl(genericPdf.group(0)!);
    return null;
  }

  /// Wrap a raw PDF URL in Google Docs viewer for in-overlay display.
  String _toPdfViewerUrl(String pdfUrl) {
    if (pdfUrl.startsWith('data:')) return pdfUrl;
    if (_isGoogleViewerUrl(pdfUrl)) return pdfUrl;
    if (!_looksLikePdfUrl(pdfUrl)) return pdfUrl;
    final encoded = Uri.encodeComponent(_unwrapViewerUrl(pdfUrl));
    return 'https://docs.google.com/viewer?url=$encoded&embedded=true';
  }

  bool _isGoogleViewerUrl(String url) {
    final l = url.toLowerCase();
    return l.contains('docs.google.com/viewer') || l.contains('viewerng/viewer');
  }

  // ══════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        extendBody: true,
        extendBodyBehindAppBar: true,
        body: Stack(
          children: [
            // ── Full-screen WebView ──────────────────────────
            if (_controller != null)
              WebViewWidget(controller: _controller!),

            // ── Loading splash ───────────────────────────────
            if (_isLoading && !_hasError)
              Container(
                color: const Color(0xFF0F172A),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Text(
                            _initials(widget.doctorName),
                            style: GoogleFonts.poppins(
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                              color: Colors.white.withValues(alpha: 0.6),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        widget.doctorName,
                        style: GoogleFonts.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Preparing consultation…',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          color: Colors.white.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 28),
                      const SizedBox(
                        width: 36,
                        height: 36,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2.5,
                        ),
                      ),
                      const SizedBox(height: 32),
                      TextButton(
                        onPressed: _confirmLeave,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white70,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 10),
                        ),
                        child: Text(
                          'Cancel',
                          style: GoogleFonts.inter(fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // ── Error overlay ────────────────────────────────
            if (_hasError)
              Container(
                color: const Color(0xFF0F172A),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.wifi_off_rounded,
                            color: Colors.white54, size: 56),
                        const SizedBox(height: 16),
                        Text(
                          'Could not load consultation',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.poppins(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _errorMsg.isNotEmpty
                              ? _errorMsg
                              : 'Please check your internet connection and try again.',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            color: Colors.white54,
                          ),
                        ),
                        const SizedBox(height: 28),
                        ElevatedButton.icon(
                          onPressed: () {
                            setState(() {
                              _hasError = false;
                              _isLoading = true;
                            });
                            _controller?.reload();
                          },
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: Text('Retry',
                              style: GoogleFonts.inter(
                                  fontWeight: FontWeight.w600)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF10B981),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 32, vertical: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24)),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text('Go back',
                              style: GoogleFonts.inter(
                                  color: Colors.white54, fontSize: 13)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // ── Prescription PDF overlay ──────────────────────
            // Slides up over the video call so the CHO can read
            // the prescription while the call keeps running.
            // UI pattern mirrors the React Native patient app's PdfViewer:
            //   • Header with title + "Open in Browser" + close buttons
            //   • Loading indicator over the WebView
            //   • Full error state with "Open in Browser" fallback
            if (_pdfController != null) ...[
              // Semi-transparent backdrop — tap to close.
              Positioned.fill(
                child: GestureDetector(
                  onTap: _closePdfOverlay,
                  child: Container(color: Colors.black54),
                ),
              ),

              // PDF panel (85 % of screen height, anchored to bottom).
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                top: MediaQuery.of(context).size.height * 0.15,
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(16)),
                  child: Column(
                    children: [
                      // ── Header bar ──────────────────────────────────────
                      // Matches RN PdfViewer header: back + title + "Open in Browser"
                      Container(
                        color: const Color(0xFF0F172A),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.picture_as_pdf_rounded,
                              color: Color(0xFF10B981),
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'View Prescription',
                                style: GoogleFonts.poppins(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            // "Open in Browser" button — mirrors RN app's top-right button.
                            GestureDetector(
                              onTap: () => _openPdfInBrowser(_currentPdfUrl),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF10B981).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                      color: const Color(0xFF10B981).withValues(alpha: 0.4)),
                                ),
                                child: Text(
                                  'Open in Browser',
                                  style: GoogleFonts.inter(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: const Color(0xFF10B981),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: _closePdfOverlay,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.white12,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Icon(
                                  Icons.close_rounded,
                                  color: Colors.white,
                                  size: 18,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // ── PDF body ─────────────────────────────────────────
                      Expanded(
                        child: _pdfError
                            // Error state — mirrors RN PdfViewer's errorContainer
                            ? Container(
                                color: Colors.white,
                                child: Center(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 32),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.picture_as_pdf_rounded,
                                            size: 56, color: Color(0xFFCCCCCC)),
                                        const SizedBox(height: 16),
                                        Text(
                                          'Unable to load PDF',
                                          textAlign: TextAlign.center,
                                          style: GoogleFonts.poppins(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                            color: const Color(0xFF444444),
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          'The prescription could not be loaded inside the app.',
                                          textAlign: TextAlign.center,
                                          style: GoogleFonts.inter(
                                              fontSize: 13, color: Colors.grey[600]),
                                        ),
                                        const SizedBox(height: 24),
                                        // "Open in Browser" retry — exactly like RN's retryButton
                                        ElevatedButton.icon(
                                          onPressed: () => _openPdfInBrowser(_currentPdfUrl),
                                          icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                                          label: Text(
                                            'Open in Browser',
                                            style: GoogleFonts.inter(
                                                fontWeight: FontWeight.w600, fontSize: 14),
                                          ),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: const Color(0xFF10B981),
                                            foregroundColor: Colors.white,
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 28, vertical: 12),
                                            shape: RoundedRectangleBorder(
                                                borderRadius: BorderRadius.circular(24)),
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                        TextButton(
                                          onPressed: _closePdfOverlay,
                                          child: Text('Close',
                                              style: GoogleFonts.inter(
                                                  color: Colors.grey[500], fontSize: 13)),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              )
                            // Normal WebView — same as RN's <WebView source={{ uri: pdfUrl }} />
                            : Stack(
                                children: [
                                  WebViewWidget(controller: _pdfController!),
                                  if (_pdfLoading)
                                    Container(
                                      color: Colors.white,
                                      child: Center(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const CircularProgressIndicator(
                                              color: Color(0xFF10B981),
                                              strokeWidth: 2.5,
                                            ),
                                            const SizedBox(height: 12),
                                            Text(
                                              'Loading prescription…',
                                              style: GoogleFonts.inter(
                                                  color: Colors.grey[600], fontSize: 13),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  // HELPERS
  // ══════════════════════════════════════════════════════════

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }

  // ── PDF overlay ────────────────────────────────────────────────────────────

  /// Open a PDF URL inside the app as a slide-up overlay.
  ///
  /// [pdfUrl] can be:
  ///   • "https://..." → load directly in WebView (cookies already injected)
  ///   • "data:application/pdf;base64,..." → load data URI in WebView
  ///
  /// Mirrors the React Native patient app's PdfViewer approach:
  ///   • Loads the URL directly — no complex auth injection
  ///   • Provides "Open in Browser" as a fallback (like RN's Linking.openURL)
  ///   • Shows error state with browser fallback (like RN's error handler)
  ///   • Clears cache before loading (like RN's cacheEnabled=false)
  ///
  /// The video call keeps running underneath.
  Future<void> _openPdfOverlay(String pdfUrl, {String? fileName}) async {
    final resolvedUrl = _toPdfViewerUrl(pdfUrl);
    debugPrint('📄 PdfOverlay: loading $pdfUrl');
    if (resolvedUrl != pdfUrl) {
      debugPrint('📄 PdfOverlay: viewer wrapped → $resolvedUrl');
    }
    _cancelPostTelemedRedirectFallback();
    _prescriptionFound = true;

    // Declare as late so the closure in onPageFinished can capture it
    // after the assignment is complete (avoids "can't reference before declared").
    late final WebViewController controller;

    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          // Guard: if the server redirects to a login page instead of serving
          // the PDF, close the overlay rather than showing a login form inside it.
          final uri = Uri.tryParse(request.url);
          if (uri != null) {
            final path = uri.path.toLowerCase();
            if (path.contains('/login') ||
                path.contains('/signin') ||
                path.contains('/accounts/login')) {
              debugPrint('📄 PdfOverlay: redirected to login → closing overlay');
              // Open in browser as fallback (like RN app's Linking.openURL on auth failure)
              _openPdfInBrowser(pdfUrl);
              _closePdfOverlay();
              return NavigationDecision.prevent;
            }
          }
          return NavigationDecision.navigate;
        },
        onPageStarted: (_) {
          if (mounted) setState(() { _pdfLoading = true; _pdfError = false; });
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _pdfLoading = false);
          // Inject auth so the PDF endpoint (which also needs auth) loads.
          _injectAuthIntoController(controller);
        },
        onWebResourceError: (e) {
          // Only surface main-frame failures as errors (like RN's onError).
          if (e.isForMainFrame == true) {
            debugPrint('⚠️ PdfOverlay load error: ${e.description}');
            if (mounted) setState(() { _pdfLoading = false; _pdfError = true; });
          }
        },
      ));

    // Android-specific: clear cache before loading (like RN's cacheEnabled=false)
    // and set software layer for reliable PDF rendering (like RN's androidLayerType="software").
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      platform.setMediaPlaybackRequiresUserGesture(false);
      try {
        // Clear stale cache so each prescription load is fresh.
        await (platform as dynamic).clearCache();
      } catch (_) {}
    }

    // Cookies are already in the WebView cookie store from _injectCookies(),
    // which runs before the main page loads — they are shared across all
    // WebViews in the same process, so the PDF controller picks them up too.
    await controller.loadRequest(Uri.parse(resolvedUrl));

    if (mounted) {
      setState(() {
        _currentPdfUrl = resolvedUrl;
        _pdfController = controller;
        _pdfLoading = true;
        _pdfError = false;
      });
    }
  }

  /// Open the PDF URL in the device's default browser / PDF app.
  /// Mirrors the React Native patient app's Linking.openURL(pdfUrl) fallback.
  ///
  /// Handles two cases:
  ///   • HTTPS URL  → launchUrl in external application
  ///   • data: URI  → decode base64, save to temp file, open with file intent
  Future<void> _openPdfInBrowser(String url) async {
    if (url.isEmpty) return;
    try {
      if (url.startsWith('data:')) {
        // Base64 PDF — extract, save to temp file, open natively
        await _saveBase64AndOpen(url);
      } else {
        final uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      }
    } catch (e) {
      debugPrint('⚠️ PdfOverlay: cannot open in browser: $e');
    }
  }

  /// Decode a data: URI base64 PDF → save to Downloads / cache → open with
  /// the system PDF viewer (same as RN chatDocumentService.saveDocument flow).
  Future<void> _saveBase64AndOpen(String dataUri) async {
    try {
      // Format: "data:application/pdf;base64,JVBERi0x..."
      final commaIdx = dataUri.indexOf(',');
      if (commaIdx < 0) return;
      final b64 = dataUri.substring(commaIdx + 1);
      final bytes = base64Decode(b64);

      // Save to app cache dir so we don't need WRITE_EXTERNAL_STORAGE permission.
      final tmpDir = await getTemporaryDirectory();
      final file = File('${tmpDir.path}/prescription_${DateTime.now().millisecondsSinceEpoch}.pdf');
      await file.writeAsBytes(bytes, flush: true);

      debugPrint('📄 PdfOverlay: saved base64 PDF → ${file.path}');

      // Open with any installed PDF viewer via ACTION_VIEW intent.
      final fileUri = Uri.file(file.path);
      if (await canLaunchUrl(fileUri)) {
        await launchUrl(fileUri, mode: LaunchMode.externalApplication);
      } else {
        debugPrint('⚠️ PdfOverlay: no PDF viewer app found to open ${file.path}');
      }
    } catch (e) {
      debugPrint('⚠️ PdfOverlay: _saveBase64AndOpen error: $e');
    }
  }

  void _closePdfOverlay() {
    _cancelPostTelemedRedirectFallback();
    if (mounted) {
      setState(() {
        _pdfController = null;
        _pdfError = false;
        _pdfLoading = false;
        _currentPdfUrl = '';
      });
      // Allow re-detection if the doctor regenerates the prescription later.
      _prescriptionFound = false;
    }
  }

  /// Inject auth token + CSRF into an arbitrary controller (used for the PDF overlay).
  void _injectAuthIntoController(WebViewController ctrl) {
    final token = _authToken ?? '';
    final safeToken = token
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'")
        .replaceAll('\n', '')
        .replaceAll('\r', '');

    ctrl.runJavaScript("""
(function(){
  var token = '$safeToken';
  function getCsrf(){
    try{var m=document.cookie.match(/(?:^|;\\s*)csrftoken=([^;]+)/);return m?decodeURIComponent(m[1]):''}catch(e){return ''}
  }
  if(!window.__choFetchPatched){
    window.__choFetchPatched=true;
    var _f=window.fetch.bind(window);
    window.fetch=function(i,o){o=o||{};try{var h=new Headers(o.headers||{});if(token&&!h.has('Authorization'))h.set('Authorization','Bearer '+token);var c=getCsrf();if(c&&!h.has('X-CSRFToken'))h.set('X-CSRFToken',c);o.headers=h}catch(e){}return _f(i,o)};
  }
  if(!window.__choXhrPatched){
    window.__choXhrPatched=true;
    var _o=XMLHttpRequest.prototype.open,_s=XMLHttpRequest.prototype.send,_r=XMLHttpRequest.prototype.setRequestHeader;
    XMLHttpRequest.prototype.open=function(){this.__ai=false;return _o.apply(this,arguments)};
    XMLHttpRequest.prototype.send=function(){if(!this.__ai){this.__ai=true;try{if(token)_r.call(this,'Authorization','Bearer '+token);var c=getCsrf();if(c)_r.call(this,'X-CSRFToken',c)}catch(e){}}return _s.apply(this,arguments)};
  }
})();
""").catchError((_) {});
  }

  void _confirmLeave() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          const Icon(Icons.call_end_rounded, color: Color(0xFFFF5252), size: 22),
          const SizedBox(width: 10),
          Text('Leave Consultation',
              style:
                  GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600)),
        ]),
        content: Text(
          'Are you sure you want to leave this consultation?',
          style: GoogleFonts.inter(fontSize: 13, color: Colors.grey[600]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Stay', style: GoogleFonts.inter(fontSize: 13)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF5252),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: Text('Leave',
                style: GoogleFonts.inter(
                    fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/video_call_service.dart';
import '../services/chat_document_service.dart';
import '../services/telemedicine_notification_service.dart';
import '../services/api_service.dart';
import 'video_consultation_webview_page.dart';
import '../widgets/chat_panel.dart';

/// Full-screen in-app video consultation screen.
/// Matches the React Native VideoConsultation.js pattern exactly:
///   - skipConsent=true  → "Start Call" button (direct join)
///   - skipConsent=false → "Request Session" button + access-grant flow
/// Features: draggable local PIP, in-call chat, doctor overlay, overlay
/// settings shortcut, waiting-notification alerts.
class VideoConsultationPage extends StatefulWidget {
  final int doctorId;
  final int? patientId;
  final String doctorName;
  final String? patientName;
  final String? roomId;
  final bool skipConsent;
  final bool autoRequestConsent;
  // ABHA ID forwarded to the WebView so it can construct the prescription URL.
  // Pattern: /prescription_api/getpdf/{abhaId}/{timestamp}.pdf
  final String? patientAbhaId;

  const VideoConsultationPage({
    super.key,
    required this.doctorId,
    required this.doctorName,
    this.patientId,
    this.patientName,
    this.roomId,
    this.skipConsent = true, // default true (matching RN skipConsent behaviour)
    this.autoRequestConsent = false,
    this.patientAbhaId,
  });

  @override
  State<VideoConsultationPage> createState() => _VideoConsultationPageState();
}

class _VideoConsultationPageState extends State<VideoConsultationPage> {
  final _vc = VideoCallService.instance;

  final _localRenderer = RTCVideoRenderer();
  // Simple approach (matching DoctorsApp): pre-initialize renderer once,
  // then just assign srcObject when remote stream arrives.
  final _remoteRenderer = RTCVideoRenderer();

  // Renderer initialization is lazy. The current CHO flow routes to WebView
  // after doctor acceptance, so we must not bootstrap flutter_webrtc while the
  // user is still on the waiting screen.
  Future<void>? _localRendererReady;
  Future<void>? _remoteRendererReady;
  bool _renderersInitialized = false;

  // ── Call state ───────────────────────────────────────────
  bool _connecting = false;
  bool _connected = false;
  bool _micOn = true;
  bool _camOn = true;
  final bool _frontCamera = true;
  String? _error;

  // Matching RN: hasRequestedConsent tracks whether the user pressed the join
  // button and the access-grant / consent request has been sent.
  bool _hasRequestedConsent = false;
  bool _roomJoinedCallbackFired = false;
  bool _hasCreatedOffer = false;
  String? _activeRoomId;
  bool _waitingForDoctorResponse = false;
  StreamSubscription? _notificationSub;   // Firestore notifications/{id} listener
  bool _acceptanceProcessed = false;      // guard: only call _initializeCall() once
  Timer? _consentTimeoutTimer;

  // ── Controls auto-hide ───────────────────────────────────
  bool _controlsVisible = true;
  Timer? _controlsTimer;

  // ── Remote stream tracking (matching RN wasRemoteConnected ref) ──
  bool _wasRemoteConnected = false;

  // Track whether remote stream has been assigned to renderer
  bool _hasRemoteStream = false;

  // ── Chat state (matching RN useChat hook) ────────────────
  final List<Map<String, dynamic>> _messages = [];
  bool _isChatOpen = false;
  int _unreadCount = 0;
  final Set<String> _seenMessageKeys = {};

  // ── Draggable PIP state (matching RN PanResponder) ───────
  late double _pipX;
  late double _pipY;
  static const double _pipW = 120;
  static const double _pipH = 160;

  // ══════════════════════════════════════════════════════════
  // LIFECYCLE
  // ══════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();

    // This screen has a full-black background — use light (white) status bar
    // icons so they are visible.  Restored to dark icons in dispose().
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);

    // Initialise PIP position (top-right corner, matching RN x=SCREEN_WIDTH-140, y=60)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final size = MediaQuery.of(context).size;
      setState(() {
        _pipX = size.width - _pipW - 20;
        _pipY = 60;
      });
    });

    // Auto-start variants:
    //   skipConsent=true   -> direct call start
    //   autoRequestConsent -> immediately trigger consent request flow
    if (widget.skipConsent) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_connecting && !_connected) {
          setState(() => _hasRequestedConsent = true);
          _initializeCall();
        }
      });
    } else if (widget.autoRequestConsent) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_connecting && !_connected && !_waitingForDoctorResponse) {
          _handleJoinPress();
        }
      });
    }
  }

  @override
  void dispose() {
    debugPrint('📞 VideoConsultation: disposing...');
    // Restore dark status bar icons for the light-coloured screens we return to.
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
    _controlsTimer?.cancel();
    _notificationSub?.cancel();
    _consentTimeoutTimer?.cancel();
    _vc.removeChatMessageListener();
    _vc.dispose();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════
  // CALL INITIALISATION (matching RN initializeCall)
  // ══════════════════════════════════════════════════════════

  Future<void> _ensureRenderersInitialized() async {
    if (_renderersInitialized) return;
    _localRendererReady ??= _localRenderer.initialize();
    _remoteRendererReady ??= _remoteRenderer.initialize();
    await _localRendererReady;
    await _remoteRendererReady;
    _renderersInitialized = true;
  }

  Future<void> _initializeCall() async {
    if (_connecting || _connected) return;

    try {
      setState(() {
        _connecting = true;
        _error = null;
      });

      debugPrint('═══════════════════════════════════════════════');
      debugPrint('🚀 STARTING VIDEO CALL INITIALIZATION');
      debugPrint('═══════════════════════════════════════════════');
      debugPrint('🚪 Room ID: $_resolvedRoomId');
      debugPrint('👤 Patient ID: ${widget.patientId}');
      debugPrint('👨‍⚕️ Doctor ID: ${widget.doctorId}');
      debugPrint('═══════════════════════════════════════════════');

      if (widget.patientId == null || widget.patientId! <= 0) {
        _setError('Patient ID missing.\nStart from a verified appointment.');
        return;
      }

      // ── Step 0: Await renderer initialization ──
      debugPrint('⏳ Step 0: Awaiting renderer initialization...');
      await _ensureRenderersInitialized();
      debugPrint('✅ Local renderer ready — textureId=${_localRenderer.textureId}');
      debugPrint('✅ Remote renderer ready — textureId=${_remoteRenderer.textureId}');

      // ── Step 1: Permissions (matching RN requestMediaPermissions) ──
      debugPrint('🔐 Step 1: Requesting media permissions...');

      final camStatus = await Permission.camera.request();
      final micStatus = await Permission.microphone.request();

      debugPrint('📹 Camera permission: $camStatus');
      debugPrint('🎤 Audio permission: $micStatus');

      if (!camStatus.isGranted || !micStatus.isGranted) {
        _setError('Camera or microphone permission denied.\n'
            'Please grant permissions in Settings.');
        return;
      }
      debugPrint('✅ Permissions granted!');

      // ── Step 2: Connect socket (matching RN videoCallService.connect()) ──
      debugPrint('🔌 Step 2: Connecting to WebSocket...');

      _vc.onMessageCallback = _handleMessage;

      _vc.connect();
      final connected = await _vc.waitForConnection();
      final status = _vc.getConnectionStatus();
      debugPrint('📡 Connection status: $status');

      if (!connected || !(status['isConnected'] as bool)) {
        _setError('Unable to connect to call server.\n'
            'Please check your internet and try again.');
        return;
      }
      debugPrint('✅ WebSocket connected, proceeding with video setup...');

      // ── Step 3: Local media (matching RN mediaDevices.getUserMedia) ──
      debugPrint('📹 Step 3: Accessing camera and microphone...');

      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': {
          'width': {'ideal': 1280},
          'height': {'ideal': 720},
          'facingMode': 'user',
        },
      });

      debugPrint('✅ Local media stream obtained!');
      debugPrint('📊 Stream: id=${stream.id}, '
          'audio=${stream.getAudioTracks().length}, '
          'video=${stream.getVideoTracks().length}');

      if (!mounted) return;
      _localRenderer.srcObject = stream;
      setState(() {});

      // ── Step 4: Peer connection (matching RN videoCallService.setupPeerConnection) ──
      debugPrint('🔗 Step 4: Setting up WebRTC peer connection...');

      await _vc.setupPeerConnection((remoteStream) {
        // Delegate to an async method so we can await renderer init.
        _onRemoteStreamReceived(remoteStream);
      });
      debugPrint('✅ Peer connection setup complete!');

      // ── Step 5: Add local stream (matching RN videoCallService.addLocalStream) ──
      debugPrint('➕ Step 5: Adding local stream to peer connection...');
      await _vc.addLocalStream(stream);
      debugPrint('✅ Local stream added to peer connection!');

      // ── Step 5b: Emit user_joining BEFORE joinRoom (matching RN) ──
      String? roomToJoin = _resolvedRoomId;
      if (roomToJoin == null || roomToJoin.isEmpty) {
        _setError('No room ID received from doctor.\nPlease try again.');
        return;
      }
      debugPrint('📤 Step 5b: Emitting user_joining...');
      _vc.emitUserJoining(
        roomId: roomToJoin,
        consultationId: roomToJoin,
        doctorId: widget.doctorId.toString(),
        patientId: widget.patientId?.toString(),
      );

      // ── Step 5c: Wait for server's user_waiting_notification ──────────────
      // The signaling server returns 'test_room' when the requested room does
      // not yet exist in its registry.  A room is only created on the signaling
      // server when the *doctor* calls joinRoom on the socket — which happens
      // when the doctor opens their video-call UI, typically a few seconds after
      // clicking "Accept".
      //
      // The server sends us 'user_waiting_notification' once the doctor has
      // created their room.  We wait up to 15 s for that event so we can join
      // the *real* room instead of getting placed in 'test_room'.
      // If the notification never arrives (doctor already joined before us, or
      // server behaves differently) we fall through and try with the API UUID.
      debugPrint('⏳ Step 5c: Waiting for server to confirm doctor\'s room (max 15 s)...');
      final serverRoomCompleter = Completer<String?>();
      const ignoredRooms = {'test_room', 'default', ''};
      _vc.onRoomIdFromServer = (serverRoom) {
        if (!ignoredRooms.contains(serverRoom) &&
            !serverRoomCompleter.isCompleted) {
          debugPrint('🎯 VideoConsultation: server confirmed room: $serverRoom');
          serverRoomCompleter.complete(serverRoom);
        }
      };
      final serverNotifiedRoom = await Future.any([
        serverRoomCompleter.future,
        Future.delayed(const Duration(seconds: 15), () => null as String?),
      ]);
      if (!mounted) return;
      if (serverNotifiedRoom != null && serverNotifiedRoom.isNotEmpty) {
        debugPrint('✅ Step 5c: adopting server room: $serverNotifiedRoom');
        setState(() {
          _activeRoomId = serverNotifiedRoom;
          roomToJoin = serverNotifiedRoom;
        });
      } else {
        debugPrint('⏱️ Step 5c: no notification in 15 s — proceeding with API room: $roomToJoin');
      }

      // ── Step 6: Join room (matching RN useVideoCall.initializeCall) ──
      // Max retries to prevent infinite loop when server keeps returning
      // test_room (doctor hasn't joined yet or room IDs don't match).
      int joinRetryCount = 0;
      const int maxJoinRetries = 10;

      void doJoinRoom(String room) {
        joinRetryCount++;
        debugPrint('📤 Step 6: Joining room=$room (attempt $joinRetryCount/$maxJoinRetries)');
        _roomJoinedCallbackFired = false; // allow re-entry on retry
        _vc.joinRoom(
          roomId: room,
          consultationId: room,
          doctorId: widget.doctorId.toString(),
          patientId: widget.patientId?.toString(),
          userType: 'patient',
          userName: (widget.patientId?.toString()) ?? 'patient',
          callback: (error, data) async {
            if (_roomJoinedCallbackFired) return;
            _roomJoinedCallbackFired = true;

            if (error != null) {
              debugPrint('❌ joinRoom error: $error');
              _setError(error);
              return;
            }

            // Check whether the server accepted our room or fell back to
            // test_room (room still doesn't exist on the server).
            final rawRoomId = (data?['roomId'] ?? '').toString();
            final serverAccepted = !ignoredRooms.contains(rawRoomId);

            debugPrint('✅ roomJoined: rawRoomId=$rawRoomId serverAccepted=$serverAccepted');

            if (!serverAccepted) {
              if (joinRetryCount >= maxJoinRetries) {
                debugPrint('❌ Max join retries ($maxJoinRetries) reached — giving up');
                _setError(
                  'Could not connect to the doctor\'s room.\n'
                  'The doctor may not have opened their video call yet.\n'
                  'Please try again.',
                );
                return;
              }
              // Server still returned test_room.  The doctor hasn't opened
              // their video-call UI yet.  Retry after 3 s.
              debugPrint('⚠️ Server returned test_room — will retry joinRoom in 3 s ($joinRetryCount/$maxJoinRetries)');
              _roomJoinedCallbackFired = false;
              await Future<void>.delayed(const Duration(seconds: 3));
              if (!mounted || _connected) return;
              // Re-use the best room ID available now (may have been updated
              // by the Firestore listener while we waited).
              final retryRoom = _resolvedRoomId ?? room;
              debugPrint('🔁 Retrying joinRoom with room=$retryRoom');
              doJoinRoom(retryRoom);
              return;
            }

            debugPrint('✅ Room joined! Sending ready signal...');
            final joinedRoomId = _vc.currentRoomId
                ?? (ignoredRooms.contains(rawRoomId) ? null : rawRoomId)
                ?? _resolvedRoomId;
            if (!mounted) return;
            setState(() {
              _connected = true;
              _connecting = false;
              _activeRoomId = joinedRoomId;
            });
            debugPrint('🔄 Active room switched to: $joinedRoomId');

            // Clear onRoomIdFromServer — we're now in the real room.
            _vc.onRoomIdFromServer = null;

            _vc.sendReady();

            final participantCount =
                (data?['participants'] as List?)?.length ?? 1;
            debugPrint('👥 Room has $participantCount participant(s) on join');

            // Match RN: always attempt to create offer after 1 s delay.
            Future.delayed(const Duration(seconds: 1), () {
              if (!mounted) return;
              debugPrint(
                  '⏱️ 1s delay: $participantCount participant(s) — creating initial offer');
              _createOfferIfNeeded();
            });
          },
        );
      }

      doJoinRoom(roomToJoin!);
    } catch (e) {
      debugPrint('═══════════════════════════════════════════════');
      debugPrint('🔴 VIDEO CALL INITIALIZATION ERROR!');
      debugPrint('❌ Error: $e');
      debugPrint('═══════════════════════════════════════════════');
      _vc.disconnect();
      _setError('Failed to start: $e');
    }
  }

  // ══════════════════════════════════════════════════════════
  // REMOTE STREAM HANDLER
  // ══════════════════════════════════════════════════════════

  /// Called when the first remote stream arrives via onTrack / onAddStream.
  ///
  /// SIMPLIFIED (matching DoctorsApp pattern): Just assign the stream to
  /// the pre-initialized renderer and call setState.  No disposal/recreation,
  /// no srcObject reload safety — the DoctorsApp works without all of that.
  Future<void> _onRemoteStreamReceived(MediaStream remoteStream) async {
    debugPrint('═══════════════════════════════════════════════');
    debugPrint('📺 REMOTE STREAM RECEIVED!');
    debugPrint('📊 Stream id=${remoteStream.id}, '
        'audio=${remoteStream.getAudioTracks().length}, '
        'video=${remoteStream.getVideoTracks().length}');
    debugPrint('═══════════════════════════════════════════════');
    if (!mounted) return;

    // Simple approach matching DoctorsApp: just assign the stream to the
    // pre-initialized renderer.  No dispose→recreate cycle needed.
    _remoteRenderer.srcObject = remoteStream;
    debugPrint('✅ srcObject assigned to pre-initialized remote renderer '
        '(textureId=${_remoteRenderer.textureId})');

    setState(() {
      _hasRemoteStream = true;
      _connected = true;
      _connecting = false;
    });

    // Force a UI rebuild after a short delay to ensure the texture widget
    // picks up the new frames (matching DoctorsApp's forceUpdate pattern).
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        debugPrint('🔄 500ms rebuild (textureId=${_remoteRenderer.textureId})');
        setState(() {});
      }
    });

    _startControlsTimer();
    _setupChatListener();
    _handleRemoteStreamConnected();
  }

  // ══════════════════════════════════════════════════════════
  // CHAT SETUP (matching RN useChat hook isConnected effect)
  // ══════════════════════════════════════════════════════════

  void _setupChatListener() {
    debugPrint('═══════════════════════════════════════════════');
    debugPrint('💬 INITIALIZING CHAT');
    debugPrint('🚪 Room ID: $_resolvedRoomId');
    debugPrint('═══════════════════════════════════════════════');

    _vc.onChatMessage(_handleIncomingChatMessage);

    // Fetch chat history
    _vc.getChatHistory(_resolvedRoomId ?? '', (err, history) {
      if (err != null || history == null) return;
      for (final raw in history) {
        if (raw is Map) {
          _addMessageFromServer(Map<String, dynamic>.from(raw));
        }
      }
    });
  }

  void _handleIncomingChatMessage(Map<String, dynamic> data) {
    debugPrint('💬 INCOMING CHAT MESSAGE: ${data['content']}');

    // Room matching (matching RN: only add messages from same room)
    final msgRoom = data['roomId'] as String? ?? data['room_id'] as String? ?? '';
    if (msgRoom.isNotEmpty && msgRoom != _resolvedRoomId) {
      debugPrint('⚠️ Message ignored – wrong room');
      return;
    }

    _addMessageFromServer(data);
  }

  void _addMessageFromServer(Map<String, dynamic> data) {
    // Normalize snake_case → camelCase (matching RN normalizedMessage)
    String extractedFileType = (data['fileType'] ?? data['file_type'] ?? '') as String;
    String? extractedFileContent =
        (data['fileContent'] ?? data['file_content']) as String?;

    final fileUrl = data['file_url'] as String?;
    if (fileUrl != null && extractedFileContent == null) {
      final mimeMatch = RegExp(r'^data:([^;]+);base64,').firstMatch(fileUrl);
      if (mimeMatch != null) {
        extractedFileType = mimeMatch.group(1)!;
        extractedFileContent = fileUrl.split(',').last;
      }
    }

    final msgType = data['message_type'] == 'file'
        ? 'document'
        : (data['type'] ?? data['message_type'] ?? 'text') as String;

    final normalized = <String, dynamic>{
      'id': data['id'] ??
          '${data['timestamp']}-${data['sender_id'] ?? data['sender']}',
      'type': msgType,
      'content': data['content'] ?? data['message'] ?? '',
      'sender': data['sender_type'] ?? data['sender'] ?? 'doctor',
      'senderId': data['senderId'] ?? data['sender_id'],
      'senderName': data['senderName'] ?? data['sender_name'],
      'timestamp': data['timestamp'] ?? DateTime.now().toIso8601String(),
      'roomId': data['roomId'] ?? data['room_id'] ?? _resolvedRoomId,
      'fileName': data['fileName'] ?? data['file_name'],
      'fileType': extractedFileType,
      'fileSize': data['fileSize'] ?? data['file_size'],
      'fileContent': extractedFileContent,
    };

    // Duplicate check (matching RN isDuplicate logic)
    final key =
        '${normalized['timestamp']}-${normalized['sender']}';
    if (_seenMessageKeys.contains(key)) {
      debugPrint('⚠️ Duplicate message ignored');
      return;
    }
    _seenMessageKeys.add(key);

    if (!mounted) return;
    setState(() {
      _messages.add(normalized);
      // Increment unread if chat closed AND message from other user
      final isFromOtherUser = normalized['sender'] != 'patient';
      if (!_isChatOpen && isFromOtherUser) {
        _unreadCount++;
      }
    });
  }

  // ══════════════════════════════════════════════════════════
  // MESSAGE HANDLER (matching RN videoCallService.onMessage)
  // ══════════════════════════════════════════════════════════

  void _handleMessage(String type, Map<String, dynamic> message) {
    debugPrint('═══════════════════════════════════════════════');
    debugPrint('📨 MESSAGE HANDLER - Type: $type');
    debugPrint('═══════════════════════════════════════════════');

    switch (type) {
      case 'offer':
        debugPrint('📥 Offer received - answer sent automatically by service');
        break;

      case 'answer':
        debugPrint('📥 Answer received - connection should establish soon');
        break;

      case 'candidate':
        debugPrint('📥 ICE candidate received and added');
        break;

      case 'ready':
        debugPrint('🟢 Peer is ready');
        _createOfferIfNeeded();
        break;

      case 'userLeft':
        debugPrint('═══════════════════════════════════════════════');
        debugPrint('⚠️ USER LEFT - OTHER PARTICIPANT DISCONNECTED');
        debugPrint('═══════════════════════════════════════════════');
        if (!mounted) return;
        _remoteRenderer.srcObject = null;
        _hasCreatedOffer = false;
        setState(() {
          _hasRemoteStream = false;
          _connected = false;
          _connecting = false;
        });
        _handleRemoteStreamDisconnected();
        break;

      case 'participantUpdate':
        final count = message['count'] ?? 0;
        debugPrint('👥 Participants: $count');
        break;
    }
  }

  // ══════════════════════════════════════════════════════════
  // REMOTE STREAM EVENTS (matching RN wasRemoteConnected effect)
  // ══════════════════════════════════════════════════════════

  void _handleRemoteStreamConnected() {
    _wasRemoteConnected = true;
    debugPrint('✅ Remote participant connected');
  }

  void _handleRemoteStreamDisconnected() {
    if (_wasRemoteConnected) {
      _wasRemoteConnected = false;
      debugPrint('⚠️ Remote participant disconnected');
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Participant Left'),
          content: const Text('The other participant has left the call.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  // ══════════════════════════════════════════════════════════
  // HELPERS
  // ══════════════════════════════════════════════════════════

  /// The room ID to use. CHO never generates its own — it must come from the
  /// doctor's side (via Firestore notification or appointment API).
  String? get _resolvedRoomId =>
      _activeRoomId ?? _vc.currentRoomId ?? widget.roomId;

  String get _displayDoctorName => widget.doctorName.isNotEmpty
      ? widget.doctorName
      : 'Doctor';

  void _setError(String msg) {
    if (!mounted) return;
    setState(() {
      _error = msg;
      _connecting = false;
    });
  }

  /// Cancel / abort the call — works from any state (connecting, waiting, error).
  /// Disconnects the socket+peer-connection and pops the screen cleanly.
  void _cancelCall() {
    debugPrint('🚫 VideoConsultation: call cancelled by user');
    _notificationSub?.cancel();
    _consentTimeoutTimer?.cancel();
    _vc.disconnect();
    if (mounted) Navigator.pop(context);
  }

  void _createOfferIfNeeded() {
    debugPrint('🔍 _createOfferIfNeeded: hasCreatedOffer=$_hasCreatedOffer, peerConn=${_vc.peerConnection != null}');
    if (_hasCreatedOffer) {
      debugPrint('⏭️ _createOfferIfNeeded: offer already created, skip');
      return;
    }
    if (_vc.peerConnection == null) {
      debugPrint('⚠️ _createOfferIfNeeded: peerConnection is null, skip');
      return;
    }
    final sigState = _vc.peerConnection!.signalingState;
    debugPrint('📶 _createOfferIfNeeded: signalingState=$sigState');
    if (sigState != null &&
        sigState != RTCSignalingState.RTCSignalingStateStable) {
      debugPrint('⏳ _createOfferIfNeeded: not stable ($sigState), skip');
      return;
    }
    debugPrint('🚀 _createOfferIfNeeded: creating offer NOW');
    _hasCreatedOffer = true;
    _vc.createOffer().then((_) {
      debugPrint('✅ Offer created and sent');
    }).catchError((e) {
      _hasCreatedOffer = false;
      debugPrint('❌ Offer error: $e');
    });
  }

  void _startControlsTimer() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _connected) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _startControlsTimer();
  }

  // ── Join press (matching RN handleJoinPress) ─────────────

  Future<void> _handleJoinPress() async {
    if (_connecting || _connected || _waitingForDoctorResponse) return;
    debugPrint('🎯 VideoConsultation: join button pressed');
    if (widget.patientId == null || widget.patientId! <= 0) {
      _setError('Patient ID missing.\nStart from a verified appointment.');
      return;
    }

    setState(() {
      _hasRequestedConsent = true;
      _waitingForDoctorResponse = true;
      _error = null;
    });

    try {
      // ── Step 1: Notify doctor via Firestore notifications collection ────
      // Match the older working CHO frontend: send one pending notification
      // and wait for that same document to be updated by the doctor portal.
      _acceptanceProcessed = false;
      String? notificationId;
      try {
        int choId = 0;
        try { choId = await ApiService.getChoId(); } catch (_) {}
        notificationId = await TelemedicineNotificationService.instance
            .sendNotificationToDoctor(
          doctorId: widget.doctorId,
          patientId: widget.patientId!,
          choId: choId,
          message:
              'Patient is requesting an immediate consultation with medical history consent granted',
        );
        debugPrint('✅ VideoConsultation: doctor notification sent id=$notificationId');
      } catch (e) {
        debugPrint('⚠️ VideoConsultation: sendNotificationToDoctor failed: $e');
      }

      // ── Step 2: Start doctor response timeout ───────────────────────────
      _consentTimeoutTimer?.cancel();
      _consentTimeoutTimer = Timer(const Duration(seconds: 90), () {
        if (!mounted || !_waitingForDoctorResponse) return;
        debugPrint('⏰ VideoConsultation: doctor response timeout');
        _notificationSub?.cancel();
        _notificationSub = null;
        setState(() { _waitingForDoctorResponse = false; });
        _setError('Doctor did not respond in time. Please try again.');
      });


      // ─────────────────────────────────────────────────────────────────────
      // Room-ID extraction helper (shared by listener & fallback).
      // ─────────────────────────────────────────────────────────────────────
      String extractRoomIdFromData(Map<String, dynamic> docData) {
        final nested = docData['data'];
        final nestedMap = nested is Map
            ? Map<String, dynamic>.from(nested)
            : <String, dynamic>{};
        return (nestedMap['roomId'] ?? nestedMap['room_id'] ??
                docData['roomId'] ?? docData['room_id'] ?? '')
            .toString().trim();
      }

      int? extractAppointmentIdFromData(Map<String, dynamic> docData) {
        final nested = docData['data'];
        final nestedMap = nested is Map
            ? Map<String, dynamic>.from(nested)
            : <String, dynamic>{};
        return int.tryParse(
          (nestedMap['appointmentId'] ?? nestedMap['appointment_id'] ??
           docData['appointmentId'] ?? docData['appointment_id'] ?? '')
              .toString(),
        );
      }

      // Track whether we've already seen 'accepted' status so we can
      // start a fallback timer the first time and avoid duplicate timers.
      bool acceptedSeenButNoRoom = false;
      Timer? roomIdFallbackTimer;

      // ─────────────────────────────────────────────────────────────────────
      // onDoctorAccepted — called ONLY when we have a confirmed roomId.
      // ─────────────────────────────────────────────────────────────────────
      Future<void> onDoctorAccepted(
        String notificationId,
        Map<String, dynamic> data,
        String roomId,
      ) async {
        if (!mounted || _acceptanceProcessed) return;
        _acceptanceProcessed = true;
        _consentTimeoutTimer?.cancel();
        roomIdFallbackTimer?.cancel();
        roomIdFallbackTimer = null;
        _notificationSub?.cancel();
        _notificationSub = null;

        int? appointmentId = extractAppointmentIdFromData(data);
        if ((appointmentId == null || appointmentId <= 0) &&
            widget.patientId != null &&
            widget.patientId! > 0) {
          try {
            final session = await ApiService.getLatestSession(
              doctorId: widget.doctorId,
              patientId: widget.patientId!,
            );
            appointmentId = session.appointmentId;
          } catch (e) {
            debugPrint('⚠️ VideoConsultation: appointment fallback lookup failed: $e');
          }
        }

        debugPrint(
          '✅ VideoConsultation: doctor accepted '
          'roomId=$roomId appointmentId=${appointmentId?.toString() ?? '-'}',
        );

        if (appointmentId == null || appointmentId <= 0) {
          _setError(
            'Doctor accepted, but appointment ID was not received.\n'
            'Please try again.',
          );
          return;
        }
        final resolvedAppointmentId = appointmentId;

        int choId = 0;
        try {
          choId = await ApiService.getChoId();
        } catch (e) {
          debugPrint('⚠️ VideoConsultation: getChoId failed, using 0: $e');
        }

        setState(() {
          _waitingForDoctorResponse = false;
          _activeRoomId = roomId;
        });
        debugPrint(
          '🌐 VideoConsultation: opening WebView VC room=$roomId appointmentId=$appointmentId doctorId=${widget.doctorId} choId=$choId',
        );
        // CRITICAL: Disconnect native Flutter socket BEFORE opening WebView.
        // The WebView's /telemed/ page will create its OWN socket connection.
        // Having both connected to the same room causes duplicate participants
        // and ICE negotiation conflicts → video won't work.
        _vc.disconnect();
        if (!mounted) return;
        await Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => VideoConsultationWebViewPage(
              roomId: roomId,
              appointmentId: resolvedAppointmentId,
              doctorId: widget.doctorId,
              choId: choId,
              patientId: widget.patientId!,
              doctorName: widget.doctorName,
              patientAbhaId: widget.patientAbhaId,
            ),
          ),
        );
      }

      // ─────────────────────────────────────────────────────────────────────
      // Fallback: if Firestore never delivers a roomId after the doctor
      // accepted, poll the appointment API as a last resort.
      // ─────────────────────────────────────────────────────────────────────
      Future<void> fallbackResolveRoom(String nId, Map<String, dynamic> lastData) async {
        if (_acceptanceProcessed || !mounted) return;
        debugPrint('⏱️ VideoConsultation: roomId fallback timer fired — polling Firestore + API...');

        // One last Firestore read — the doctor portal may have just written it.
        try {
          final latest = await TelemedicineNotificationService.instance
              .getNotificationData(nId);
          if (latest != null) {
            final rid = extractRoomIdFromData(latest);
            if (rid.isNotEmpty) {
              debugPrint('✅ VideoConsultation: fallback Firestore read found roomId=$rid');
              onDoctorAccepted(nId, latest, rid);
              return;
            }
          }
        } catch (_) {}

        // Firestore still empty → try appointment API.
        try {
          final session = await ApiService.getLatestSession(
            doctorId: widget.doctorId,
            patientId: widget.patientId!,
          );
          if (session.roomId != null && session.roomId!.isNotEmpty) {
            debugPrint('✅ VideoConsultation: fallback API found roomId=${session.roomId}');
            onDoctorAccepted(nId, lastData, session.roomId!);
            return;
          }
        } catch (e) {
          debugPrint('⚠️ VideoConsultation: fallback API failed: $e');
        }

        // Nothing worked.
        if (!mounted || _acceptanceProcessed) return;
        _acceptanceProcessed = true;
        _notificationSub?.cancel();
        _notificationSub = null;
        setState(() { _waitingForDoctorResponse = false; });
        _setError(
          'Doctor accepted, but room assignment was not received.\n'
          'Please try again.',
        );
      }

      void onDoctorRejected() {
        if (!mounted || _acceptanceProcessed) return;
        _acceptanceProcessed = true;
        _consentTimeoutTimer?.cancel();
        roomIdFallbackTimer?.cancel();
        roomIdFallbackTimer = null;
        _notificationSub?.cancel();
        _notificationSub = null;
        setState(() { _waitingForDoctorResponse = false; });
        _setError('Doctor rejected the consultation request.');
      }

      // ── Step 3: Listen on Firestore notifications/{id} ──────────────────
      //
      // CRITICAL FIX: The doctor portal writes status='accepted' FIRST
      // (without roomId), then creates the appointment and writes
      // data.roomId back to the SAME Firestore document a few seconds later.
      //
      // Old code triggered onDoctorAccepted on the first 'accepted'
      // snapshot (no roomId) → resolveAcceptedSession picked up a stale
      // room from the API → room mismatch → black screen.
      //
      // New code: only fire onDoctorAccepted when the snapshot actually
      // contains a non-empty roomId.  If 'accepted' arrives without a
      // roomId, we start a 20 s fallback timer but keep listening.
      if (notificationId != null && notificationId.isNotEmpty) {
        _notificationSub?.cancel();
        _notificationSub = TelemedicineNotificationService.instance
            .waitForDoctorResponse(
          notificationId,
          onResponse: (accepted, data, status) {
            final roomId = extractRoomIdFromData(data);
            debugPrint(
                '📋 VideoConsultation: Firestore notification '
                'accepted=$accepted status=$status roomId=${roomId.isEmpty ? '(empty)' : roomId}');

            if (!accepted) {
              onDoctorRejected();
              return;
            }

            // ── Accepted WITH a roomId → go! ─────────────────────────────
            if (roomId.isNotEmpty) {
              debugPrint('🎯 VideoConsultation: Firestore delivered roomId=$roomId — proceeding');
              onDoctorAccepted(notificationId!, data, roomId);
              return;
            }

            // ── Accepted WITHOUT roomId → wait for next snapshot ─────────
            if (!acceptedSeenButNoRoom) {
              acceptedSeenButNoRoom = true;
              debugPrint('⏳ VideoConsultation: accepted but no roomId yet — '
                  'starting 20 s fallback timer, keeping listener alive');
              roomIdFallbackTimer?.cancel();
              roomIdFallbackTimer = Timer(const Duration(seconds: 20), () {
                fallbackResolveRoom(notificationId!, data);
              });
            } else {
              debugPrint('⏳ VideoConsultation: still waiting for roomId in Firestore...');
            }
          },
        );
        debugPrint('👂 VideoConsultation: listening on notifications/$notificationId');
      }
    } catch (e) {
      debugPrint('❌ VideoConsultation: consent flow failed: $e');
      _consentTimeoutTimer?.cancel();
      _setError('Failed to request doctor approval: $e');
      if (mounted) {
        setState(() { _waitingForDoctorResponse = false; });
      }
    }
  }

  // ── End call (matching RN handleEndCall) ─────────────────

  void _handleEndCall() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          const Icon(Icons.call_end_rounded,
              color: Color(0xFFFF5252), size: 22),
          const SizedBox(width: 10),
          Text('End Call',
              style: GoogleFonts.poppins(
                  fontSize: 15, fontWeight: FontWeight.w600)),
        ]),
        content: Text(
          'Are you sure you want to end this consultation?',
          style:
              GoogleFonts.inter(fontSize: 13, color: Colors.grey[600]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: GoogleFonts.inter(fontSize: 13)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _messages.clear(); // matching RN clearMessages()
              // Use disconnect() (full teardown: leaveRoom + socket close).
              // The widget's dispose() will also fire after Navigator.pop,
              // but disconnect() is idempotent, so double-calling is safe.
              _vc.disconnect();
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF5252),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: Text('End Call',
                style: GoogleFonts.inter(
                    fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  // ── Chat toggle (matching RN handleChatToggle) ────────────

  void _handleChatToggle() {
    setState(() {
      _isChatOpen = !_isChatOpen;
      if (_isChatOpen) _unreadCount = 0; // clear unread on open
    });
  }

  // ── Overlay settings (matching RN handleOverlaySettings) ──

  Future<void> _handleOverlaySettings() async {
    // Try to open Android system overlay permission settings
    // (android.settings.action.MANAGE_OVERLAY_PERMISSION)
    final uri = Uri.parse('android.settings.action.MANAGE_OVERLAY_PERMISSION');
    final launched = await launchUrl(uri).catchError((_) => false);
    if (!launched) {
      // Fallback: open general app settings
      final opened = await openAppSettings();
      if (!opened && mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Permission'),
            content: const Text(
                'Please enable "Display over other apps" in your phone Settings.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('OK'))
            ],
          ),
        );
      }
    }
  }

  // ── Send chat message (matching RN sendMessage) ───────────

  void _sendChatMessage(Map<String, dynamic> data) {
    final newMsg = {
      ...data,
      'id': '${data['timestamp']}-${data['sender']}',
      'roomId': _resolvedRoomId,
    };
    // Optimistic local add
    final key = '${newMsg['timestamp']}-${newMsg['sender']}';
    _seenMessageKeys.add(key);
    setState(() => _messages.add(newMsg));

    _vc.sendChatMessage(newMsg);
  }

  void _sendDocumentMessage(Map<String, dynamic> data) {
    final newMsg = {
      ...data,
      'id': '${data['timestamp']}-${data['sender']}',
      'roomId': _resolvedRoomId,
      'message_type': 'file',
    };
    final key = '${newMsg['timestamp']}-${newMsg['sender']}';
    _seenMessageKeys.add(key);
    setState(() => _messages.add(newMsg));
    _vc.sendChatMessage(newMsg);
  }

  Future<void> _openDocument(Map<String, dynamic> msg) async {
    try {
      await ChatDocumentService.instance.openDocument(
        fileName: (msg['fileName'] ?? 'document.pdf').toString(),
        fileContent: msg['fileContent']?.toString(),
        localFilePath: msg['localFilePath']?.toString(),
        fileUri: msg['fileUri']?.toString(),
      );
    } catch (e) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Cannot Open Document'),
          content: Text('Failed to open document: $e'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  // ── Status text (matching RN getStatusText) ───────────────

  String _getStatusText() {
    if (_connecting) return 'Connecting...';
    if (_waitingForDoctorResponse) {
      return 'Waiting for doctor approval...';
    }
    // After _initializeCall() completes (_roomJoinedCallbackFired) but remote
    // stream hasn't arrived yet — CHO is in the room waiting for the doctor.
    if (_roomJoinedCallbackFired && !_connected) {
      return 'Waiting for doctor to join...';
    }
    // Doctor accepted but _initializeCall hasn't fired yet
    if (_hasRequestedConsent && !_connected) {
      return 'Doctor accepted — starting call...';
    }
    if (_connected) return 'Connected';
    return 'Your consultation will start soon';
  }

  // ══════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════



  @override
  Widget build(BuildContext context) {
    // Hardware back button = end call (matching RN BackHandler)
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleEndCall();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          onTap: _connected ? _toggleControls : null,
          child: Stack(
            children: [
              // ── Full-screen remote video (always in tree) ──
              _buildRemoteVideo(),

              // ── Doctor placeholder (shown until remote stream arrives) ──
              if (!_connected || !_hasRemoteStream)
                Positioned.fill(child: _buildDoctorPlaceholder()),

              // ── Gradient overlay ─────────────────────────
              _buildGradientOverlay(),

              // ── Loading overlay ──────────────────────────
              if (_connecting && _error == null) _buildConnectingOverlay(),

              // ── Doctor name (bottom centre) ──────────────
              if (_connected && _hasRemoteStream)
                _buildDoctorName(),

              // ── Control buttons (bottom) ─────────────────
              if (_connected)
                _buildControls(),

              // ── Status / join section (centre) ───────────
              // Only show when NOT actively connecting — when _connecting=true
              // the _buildConnectingOverlay() already owns the centre of the screen
              // (spinner + Cancel button). Showing BOTH overlays simultaneously
              // hides the spinner behind the status box and makes the screen look
              // like a pure-black screen with no feedback.
              if (!_connected && !_connecting)
                _buildStatusSection(),

              // ── Visible waiting overlay for request state ─
              if (_waitingForDoctorResponse && !_connecting)
                _buildDoctorRequestOverlay(),

              // ── Draggable local PIP ──────────────────────
              if (_localRenderer.srcObject != null) _buildLocalPIP(),

              // ── Error overlay ────────────────────────────
              if (_error != null) _buildErrorOverlay(),

              // ── DEBUG overlay — remove before production release ──────────
              // Always visible so we can diagnose state even when screen looks
              // completely black.  Shows: connected, connecting, srcObject set,
              // textureId, firstFrame received.
              Positioned(
                top: 48, left: 8,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'conn:$_connected '
                      'ing:$_connecting '
                      'src:${_remoteRenderer.srcObject != null ? "✓" : "✗"} '
                      'tid:${_remoteRenderer.textureId ?? "?"} '
                      'rmt:$_hasRemoteStream',
                      style: const TextStyle(
                        color: Color(0xFFFFEB3B),
                        fontSize: 9.5,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ),

              // ── Chat panel (slide-in from right) ─────────
              ChatPanel(
                visible: _isChatOpen,
                onClose: () => setState(() {
                  _isChatOpen = false;
                }),
                messages: _messages,
                onSendMessage: _sendChatMessage,
                onSendDocument: _sendDocumentMessage,
                onOpenDocument: _openDocument,
                currentUserRole: 'patient',
                currentUserName: widget.patientName ?? 'Patient',
                currentUserId: widget.patientId?.toString(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  // BUILD HELPERS
  // ══════════════════════════════════════════════════════════

  /// Remote video full-screen.
  ///
  /// CRITICAL: RTCVideoView MUST always be in the widget tree — never
  /// conditionally added/removed.  If RTCVideoView is absent when srcObject is
  /// first set and then added afterwards, the plugin calls setVideoTrack a
  /// SECOND time when the widget mounts, which triggers:
  ///   EglRenderer: Releasing → eglBase detach and release → EglRenderer: Releasing done
  ///   EglRenderer: Initializing EglRenderer
  /// This second release+reinit happens while the decoder is already sending
  /// frames, disconnecting the SurfaceTexture from the render pipeline and
  /// producing a permanent black screen even though audio works.
  ///
  /// By keeping RTCVideoView in the tree at all times, EglRenderer initializes
  /// ONCE (when the widget first mounts at page load), and subsequent
  /// srcObject assignments just wire the video track without any teardown.
  /// The doctor-placeholder Stack layer covers the black renderer until the
  /// stream arrives.
  Widget _buildRemoteVideo() {
    return Positioned.fill(
      child: SizedBox.expand(
        child: RTCVideoView(
          _remoteRenderer,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        ),
      ),
    );
  }

  Widget _buildDoctorPlaceholder() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1A1A2E), Color(0xFF16213E), Color(0xFF0F3460)],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  _getInitials(_displayDoctorName),
                  style: GoogleFonts.poppins(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              _displayDoctorName,
              style: GoogleFonts.poppins(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.white.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Gradient overlay at the bottom (matching RN gradientOverlay)
  Widget _buildGradientOverlay() {
    return Positioned(
      bottom: 0, left: 0, right: 0,
      height: 300,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                Colors.black.withValues(alpha: 0.6),
                Colors.transparent,
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Connecting spinner overlay (matching RN loadingOverlay)
  Widget _buildConnectingOverlay() {
    return Positioned.fill(
      child: Container(
        // Reduced to 0.45 so the doctor-placeholder gradient behind it remains
        // visible — previously 0.7 made the combined stack look completely black.
        color: Colors.black.withValues(alpha: 0.45),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 44, height: 44,
                child: CircularProgressIndicator(
                    color: Colors.white, strokeWidth: 3),
              ),
              const SizedBox(height: 16),
              Text(
                'Connecting...',
                style: GoogleFonts.inter(
                    fontSize: 16,
                    color: Colors.white,
                    fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 24),
              // Cancel button — lets the CHO abort during the connecting phase.
              TextButton(
                onPressed: _cancelCall,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: Colors.white.withValues(alpha: 0.15),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 32, vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24)),
                ),
                child: Text(
                  'Cancel',
                  style: GoogleFonts.inter(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Doctor name overlay at bottom (matching RN doctorInfoContainer)
  Widget _buildDoctorName() {
    return Positioned(
      bottom: 140, left: 0, right: 0,
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: _controlsVisible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 20, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _displayDoctorName,
                style: GoogleFonts.poppins(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                  letterSpacing: 0.5,
                  shadows: const [
                    Shadow(
                      color: Colors.black54,
                      blurRadius: 4,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Bottom control bar (matching RN controlsWrapper / controlsBar)
  Widget _buildControls() {
    return Positioned(
      bottom: 0, left: 0, right: 0,
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              30, 20, 30,
              MediaQuery.of(context).padding.bottom + 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Overlay settings button (matching RN overlaySettingsButton)
              GestureDetector(
                onTap: _handleOverlaySettings,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                        color: Colors.white.withValues(alpha: 0.28)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.picture_in_picture_alt_rounded,
                          color: Colors.white, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        'Overlay',
                        style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),

              // Control buttons row
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Mic
                  _CtrlBtn(
                    icon: _micOn
                        ? Icons.mic_rounded
                        : Icons.mic_off_rounded,
                    active: !_micOn,
                    onTap: () {
                      setState(() => _micOn = !_micOn);
                      _vc.toggleAudio(_micOn);
                      _startControlsTimer();
                    },
                  ),
                  const SizedBox(width: 22),

                  // Chat (matching RN chat button with unread badge)
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      _CtrlBtn(
                        icon: _isChatOpen
                            ? Icons.chat_bubble_rounded
                            : Icons.chat_bubble_outline_rounded,
                        active: _isChatOpen,
                        onTap: _handleChatToggle,
                      ),
                      if (_unreadCount > 0)
                        Positioned(
                          top: 4, right: 4,
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEF4444),
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: Colors.white, width: 1.5),
                            ),
                            constraints: const BoxConstraints(
                                minWidth: 18, minHeight: 18),
                            child: Center(
                              child: Text(
                                _unreadCount > 9
                                    ? '9+'
                                    : '$_unreadCount',
                                style: GoogleFonts.inter(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 22),

                  // Camera
                  _CtrlBtn(
                    icon: _camOn
                        ? Icons.videocam_rounded
                        : Icons.videocam_off_rounded,
                    active: !_camOn,
                    onTap: () {
                      setState(() => _camOn = !_camOn);
                      _vc.toggleVideo(_camOn);
                      _startControlsTimer();
                    },
                  ),
                  const SizedBox(width: 22),

                  // End call
                  _CtrlBtn(
                    icon: Icons.call_end_rounded,
                    isEnd: true,
                    onTap: _handleEndCall,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Status / join section (matching RN statusContainer)
  Widget _buildStatusSection() {
    return Positioned.fill(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _getStatusText(),
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    color: Colors.white,
                    shadows: const [
                      Shadow(
                          color: Colors.black54,
                          blurRadius: 4,
                          offset: Offset(0, 2))
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _waitingForDoctorResponse
                      ? 'Doctor notification is being sent. Please keep this screen open.'
                      : (widget.skipConsent && _hasRequestedConsent
                          ? 'Connecting to your consultation. Doctor will join shortly.'
                          : widget.skipConsent
                              ? 'Tap below to start the video consultation.'
                              : 'Tap below to request the doctor for a live consultation.'),
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: 0.78),
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 24),
                // "Cancel Call" shown after room is joined but doctor hasn't arrived yet.
                if (_roomJoinedCallbackFired && !_connected)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: TextButton(
                      onPressed: _cancelCall,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        backgroundColor: Colors.white.withValues(alpha: 0.12),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 36, vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24)),
                      ),
                      child: Text(
                        'Cancel Call',
                        style: GoogleFonts.inter(
                            fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),

                // Hide button if already connecting or already joined room (_roomJoinedCallbackFired)
                if (!_connecting && !_roomJoinedCallbackFired)
                  GestureDetector(
                    // skipConsent=true  → go directly to _initializeCall (no doctor notification needed)
                    // skipConsent=false → full doctor-notification flow via _handleJoinPress
                    onTap: _waitingForDoctorResponse
                        ? null
                        : (widget.skipConsent ? _initializeCall : _handleJoinPress),
                    child: Opacity(
                      opacity: _waitingForDoctorResponse ? 0.7 : 1,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 40, vertical: 16),
                        decoration: BoxDecoration(
                          color: _waitingForDoctorResponse
                              ? const Color(0xFF475569)
                              : const Color(0xFF10B981),
                          borderRadius: BorderRadius.circular(30),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 6,
                              offset: const Offset(0, 4),
                            )
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_waitingForDoctorResponse)
                              const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2.4,
                                ),
                              )
                            else
                              const Icon(Icons.video_call_rounded,
                                  color: Colors.white, size: 28),
                            const SizedBox(width: 10),
                            Text(
                              _waitingForDoctorResponse
                                  ? 'Request Sent'
                                  : (widget.skipConsent
                                      ? 'Start Call'
                                      : 'Request Session'),
                              style: GoogleFonts.inter(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDoctorRequestOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          color: Colors.black.withValues(alpha: 0.18),
          child: Align(
            alignment: Alignment.topCenter,
            child: Container(
              margin: const EdgeInsets.only(top: 72),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A).withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2.2,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Waiting for doctor response',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Draggable local PIP (matching RN Animated.View + PanResponder)
  Widget _buildLocalPIP() {
    return Positioned(
      left: _pipX,
      top: _pipY,
      child: GestureDetector(
        onPanUpdate: (details) {
          final size = MediaQuery.of(context).size;
          setState(() {
            _pipX = (_pipX + details.delta.dx)
                .clamp(20.0, size.width - _pipW - 20);
            _pipY = (_pipY + details.delta.dy)
                .clamp(60.0, size.height - _pipH - 80);
          });
        },
        child: Container(
          width: _pipW,
          height: _pipH,
          decoration: BoxDecoration(
            color: const Color(0xFF1F1F1F),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [
              BoxShadow(
                  color: Colors.black54,
                  blurRadius: 6,
                  offset: Offset(0, 4))
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              // Video or "camera off" indicator
              if (_camOn && _localRenderer.srcObject != null)
                RTCVideoView(
                  _localRenderer,
                  // KEY FIX: Same as remote renderer — forces a clean Texture
                  // widget binding so local preview doesn't show black.
                  key: ValueKey(_localRenderer.textureId ?? -2),
                  mirror: _frontCamera,
                  objectFit:
                      RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                )
              else
                Container(
                  color: const Color(0xFF0F172A),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.videocam_off_rounded,
                          color: Colors.white, size: 26),
                      const SizedBox(height: 6),
                      Text(
                        'Video Off',
                        style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.white),
                      ),
                    ],
                  ),
                ),

              // Drag handle (matching RN dragHandle)
              Positioned(
                top: 8, left: 0, right: 0,
                child: Center(
                  child: Container(
                    width: 30, height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Error overlay
  Widget _buildErrorOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.85),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline_rounded,
                    size: 48, color: Color(0xFFFF5252)),
                const SizedBox(height: 16),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                      fontSize: 14,
                      color: Colors.white.withValues(alpha: 0.8),
                      height: 1.4),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: () {
                    _vc.disconnect();
                    Navigator.pop(context);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF5252),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Go Back'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Misc helpers ─────────────────────────────────────────

  String _getInitials(String name) {
    final parts = name
        .replaceAll(RegExp(r'[Dd]r\.?'), '')
        .trim()
        .split(' ')
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '${parts[0][0]}${parts.last[0]}'.toUpperCase();
  }
}

// ══════════════════════════════════════════════════════════════
// Control button widget (matching RN controlButton styles)
// ══════════════════════════════════════════════════════════════
class _CtrlBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool active;
  final bool isEnd;

  const _CtrlBtn({
    required this.icon,
    required this.onTap,
    this.active = false,
    this.isEnd = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: isEnd ? 64 : 60,
        height: isEnd ? 64 : 60,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isEnd
              ? const Color(0xFFEF4444)
              : active
                  ? const Color(0xFFEF4444).withValues(alpha: 0.95)
                  : Colors.white.withValues(alpha: 0.3),
          boxShadow: const [
            BoxShadow(
                color: Colors.black38,
                blurRadius: 5,
                offset: Offset(0, 3))
          ],
        ),
        child: Icon(icon, color: Colors.white, size: 26),
      ),
    );
  }
}

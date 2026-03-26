import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../utils/env_config.dart';

/// Mirrors the React Native videoCallService.js exactly.
///
/// Usage sequence (matching RN useVideoCall hook):
///   1. connect()
///   2. wait ~1s, check isConnected
///   3. setupPeerConnection(onRemoteStream)
///   4. addLocalStream(stream)
///   5. emitUserJoining(...)
///   6. joinRoom(..., callback)
///   7. on callback success → sendReady()
///   8. onMessage(handler) for offer/answer/candidate/ready/userLeft
class VideoCallService {
  VideoCallService._();
  static final VideoCallService instance = VideoCallService._();

  // ── Socket ──────────────────────────────────────────────
  io.Socket? _socket;
  bool get isConnected => _socket?.connected ?? false;
  Completer<bool>? _connectCompleter;

  // ── WebRTC ──────────────────────────────────────────────
  RTCPeerConnection? peerConnection;
  MediaStream? localStream;
  MediaStream? remoteStream;
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];

  String? _roomId;
  void Function(String? error, Map<String, dynamic>? data)? _onRoomJoined;
  Timer? _joinFallbackTimer;

  // Guard: track the last remote stream ID we called onRemoteStream() with.
  // onTrack fires once per track (audio + video = 2 calls) and onAddStream
  // fires a third time — all three carry the SAME stream object.  Each call
  // triggers EglRenderer release+reinit which disconnects the PlatformView
  // from the native renderer, causing a permanent black screen.
  // We only forward the callback when the stream ID actually changes.
  String? _lastRemoteStreamId;

  // ── External callbacks (set by the screen/hook) ─────────
  void Function(String type, Map<String, dynamic> message)? onMessageCallback;
  void Function(Map<String, dynamic>)? onWaitingNotification;

  // Fired when user_waiting_notification carries a roomId — the server-assigned
  // UUID room that the doctor's FCM also uses.  Screen uses this to fix the
  // room mismatch before calling joinRoom.
  void Function(String roomId)? onRoomIdFromServer;

  // ── Chat callback (matching RN chatMessageCallback) ──────
  void Function(Map<String, dynamic>)? chatMessageCallback;
  String? get currentRoomId => _roomId;

  // ═══════════════════════════════════════════════════════
  // 1. SOCKET.IO CONNECTION
  // ═══════════════════════════════════════════════════════

  void connect() {
    // ── Matching RN: if (this.socket?.connected) return this.socket; ──
    if (_socket != null && (_socket?.connected ?? false)) {
      debugPrint('✅ VideoCall: socket already connected (id=${_socket!.id}), reusing');
      // Ensure completer is resolved so waitForConnection() returns immediately
      if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
        _connectCompleter!.complete(true);
      }
      return;
    }

    final baseUrl = EnvConfig.telemedicineBaseUrl;
    final socketPath = EnvConfig.socketPath;

    debugPrint('═══════════════════════════════════════════════');
    debugPrint('🔌 VideoCall: connecting to $baseUrl');
    debugPrint('📍 Socket path: $socketPath');
    debugPrint('═══════════════════════════════════════════════');

    _socket?.dispose();
    _connectCompleter = Completer<bool>();

    _socket = io.io(
      baseUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setPath(socketPath)
          .enableReconnection()
          .setReconnectionDelay(1000)
          .setReconnectionAttempts(5)
          .setTimeout(10000)
          .build(),
    );

    _socket!.onConnect((_) {
      debugPrint('✅ VideoCall: socket connected (id=${_socket!.id})');
      if (!(_connectCompleter?.isCompleted ?? true)) {
        _connectCompleter!.complete(true);
      }
    });

    _socket!.onDisconnect((reason) {
      debugPrint('⚠️ VideoCall: socket disconnected (reason=$reason)');
    });

    _socket!.onConnectError((err) {
      debugPrint('❌ VideoCall: connect error: $err');
      if (!(_connectCompleter?.isCompleted ?? true)) {
        _connectCompleter!.complete(false);
      }
    });

    _socket!.onError((err) {
      debugPrint('❌ VideoCall: socket error: $err');
      if (_onRoomJoined != null) {
        _onRoomJoined!.call(err.toString(), null);
        _onRoomJoined = null;
      }
    });

    _socket!.on('reconnect', (attempt) {
      debugPrint('🔄 VideoCall: reconnected after $attempt attempts');
      // Match the reference app: rejoin using the plain roomId string.
      if (_lastJoinRoomId != null && _lastJoinRoomId!.isNotEmpty) {
        debugPrint('🔁 VideoCall: rejoining room=$_lastJoinRoomId');
        _socket?.emit('joinRoom', _lastJoinRoomId);
        if (_roomId != null) {
          sendReady();
        }
      }
    });

    _socket!.on('reconnect_attempt', (attempt) {
      debugPrint('🔄 VideoCall: reconnect attempt #$attempt');
    });

    _socket!.on('reconnect_failed', (_) {
      debugPrint('❌ VideoCall: all reconnect attempts failed');
      if (!(_connectCompleter?.isCompleted ?? true)) {
        _connectCompleter!.complete(false);
      }
    });

    // ── Room events ──
    _socket!.on('roomJoined', (data) {
      _joinFallbackTimer?.cancel();
      _joinFallbackTimer = null;
      debugPrint('✅ VideoCall: roomJoined: $data');
      if (data is Map && data['roomId'] != null) {
        final serverRoomId = data['roomId'].toString();
        // Guard: ignore known bogus/default room IDs the server returns when
        // it fails to parse the joinRoom payload correctly.
        const ignoredRoomIds = {'test_room', 'default', ''};
        if (serverRoomId.isNotEmpty &&
            serverRoomId != _roomId &&
            !ignoredRoomIds.contains(serverRoomId)) {
          debugPrint(
            '🔄 VideoCall: adopting server roomId=$serverRoomId (was ${_roomId ?? '-'})',
          );
          _roomId = serverRoomId;
        } else if (ignoredRoomIds.contains(serverRoomId)) {
          debugPrint(
            '⚠️ VideoCall: ignoring bogus server roomId=$serverRoomId, keeping $_roomId',
          );
        }
      }
      _onRoomJoined?.call(
        null,
        data is Map ? Map<String, dynamic>.from(data) : {},
      );
      _onRoomJoined = null;
    });

    _socket!.on('participantUpdate', (data) {
      final count = (data is Map) ? (data['count'] ?? 0) : 0;
      debugPrint('👥 VideoCall: participants = $count');
      onMessageCallback?.call('participantUpdate', {'count': count});
    });

    _socket!.on('ready', (data) {
      debugPrint('🟢 VideoCall: peer ready event received');
      onMessageCallback?.call('ready', data is Map ? Map<String, dynamic>.from(data) : {});
    });

    _socket!.on('userLeft', (data) {
      debugPrint('👋 VideoCall: userLeft event');
      onMessageCallback?.call('userLeft', data is Map ? Map<String, dynamic>.from(data) : {});
    });

    _socket!.on('user_waiting_notification', (data) {
      debugPrint('⏳ VideoCall: user_waiting_notification: $data');
      if (data is Map) {
        final dataMap = Map<String, dynamic>.from(data);
        // Extract the server-assigned UUID room so the screen can use it for
        // joinRoom (avoiding the consult_X_Y → test_room mismatch).
        final serverRoom = (dataMap['roomId']
                ?? dataMap['room_id']
                ?? dataMap['consultationId']
                ?? dataMap['consultation_id']
                ?? dataMap['prescriptionId']?.toString()
                ?? dataMap['prescription_id']?.toString())
            ?.toString();
        if (serverRoom != null && serverRoom.isNotEmpty) {
          debugPrint('🎯 VideoCall: server room UUID from waiting notification: $serverRoom');
          onRoomIdFromServer?.call(serverRoom);
        }
        onWaitingNotification?.call(dataMap);
      }
    });

    // ── Signaling messages ──
    _socket!.on('message', (data) {
      if (data is! Map) return;
      final msg = Map<String, dynamic>.from(data);

      // Normalize: if type is missing but message_type exists, it's a chat message
      // (matching RN: if (!message.type && message.message_type) { message.type = 'chat'; })
      if (msg['type'] == null && msg['message_type'] != null) {
        msg['type'] = 'chat';
      }

      final type = msg['type'] as String?;
      if (type == null) return;

      debugPrint('═══════════════════════════════════════════════');
      debugPrint('📨 VideoCall: message type=$type');
      debugPrint('═══════════════════════════════════════════════');

      // Internal signaling handling
      switch (type) {
        case 'offer':
          _handleOffer(msg);
          break;
        case 'answer':
          _handleAnswer(msg);
          break;
        case 'candidate':
          _handleCandidate(msg);
          break;
        case 'chat':
        case 'document':
        case 'text':
          // DoctorsApp spreads messageData AFTER type:'chat', so the original
          // type ('document' / 'text') may override it.  Treat all three as
          // chat messages so PDFs and texts are forwarded to the chat panel.
          debugPrint('💬 VideoCall: chat message received (type=$type)');
          chatMessageCallback?.call(msg);
          break;
      }

      // Forward ALL messages to the external handler (screen/hook)
      onMessageCallback?.call(type, msg);
    });

    _socket!.connect();
  }

  Future<bool> waitForConnection({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (isConnected) return true;

    final completer = _connectCompleter ??= Completer<bool>();
    try {
      return await completer.future.timeout(timeout, onTimeout: () => false);
    } catch (_) {
      return false;
    }
  }

  /// Get connection status (matching RN getConnectionStatus)
  Map<String, dynamic> getConnectionStatus() {
    return {
      'isConnected': isConnected,
      'socketId': _socket?.id,
      'serverUrl': EnvConfig.telemedicineBaseUrl,
    };
  }

  // ═══════════════════════════════════════════════════════
  // 2. WEBRTC PEER CONNECTION
  // ═══════════════════════════════════════════════════════

  Map<String, dynamic> get _iceConfig {
    final servers = <Map<String, dynamic>>[
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:global.stun.twilio.com:3478'},
    ];

    final turnUrl = EnvConfig.webrtcTurnUrl;
    if (turnUrl.isNotEmpty) {
      servers.add({
        'urls': turnUrl,
        'username': EnvConfig.webrtcTurnUsername,
        'credential': EnvConfig.webrtcTurnCredential,
      });
    }

    return {'iceServers': servers};
  }

  /// Step 3 in RN: setupPeerConnection(onRemoteStream)
  Future<void> setupPeerConnection(void Function(MediaStream) onRemoteStream) async {
    debugPrint('🔗 VideoCall: setting up peer connection...');
    _pendingRemoteCandidates.clear();

    peerConnection = await createPeerConnection(_iceConfig);

    peerConnection!.onTrack = (RTCTrackEvent event) async {
      debugPrint('═══════════════════════════════════════════════');
      debugPrint('📺 VideoCall: REMOTE TRACK RECEIVED (kind=${event.track.kind})');
      debugPrint('═══════════════════════════════════════════════');

      if (event.streams.isNotEmpty) {
        final stream = event.streams[0];
        remoteStream = stream;
        debugPrint('📊 Remote stream: id=${stream.id}, '
            'audio=${stream.getAudioTracks().length}, '
            'video=${stream.getVideoTracks().length}');

        // DEDUP + VIDEO-GUARD:
        //
        // onTrack fires ONCE PER TRACK (audio → call 1, video → call 2).
        // Both calls carry the SAME stream object (same .id).
        //
        // The old dedup fired onRemoteStream on the FIRST track seen — which
        // is often the AUDIO track, before the video track has been added to
        // the stream.  Binding the renderer to an audio-only stream makes
        // EglRenderer show a permanent black frame even though audio works.
        //
        // NEW RULE: Only forward to the renderer when the stream contains at
        // least one video track.  This way:
        //   - audio-track event  → skip (no video yet, don't bind renderer)
        //   - video-track event  → stream now has video → bind renderer ✓
        //   - onAddStream        → stream always complete → bind renderer ✓
        final hasVideo = stream.getVideoTracks().isNotEmpty;
        if (stream.id != _lastRemoteStreamId && hasVideo) {
          _lastRemoteStreamId = stream.id;
          debugPrint('🆕 VideoCall: NEW remote stream WITH video '
              '(v=${stream.getVideoTracks().length}, '
              'a=${stream.getAudioTracks().length}) — forwarding to renderer');
          onRemoteStream(stream);
        } else if (!hasVideo) {
          debugPrint('⏳ VideoCall: stream ${stream.id} has no video yet '
              '(audio-only) — skipping renderer bind, waiting for video track');
        } else {
          debugPrint('♻️  VideoCall: same stream ID (${stream.id}) '
              '— skipping duplicate callback');
        }
      } else {
        // Fallback: onTrack fired without a stream (some WebRTC implementations).
        // We manually assemble a MediaStream from the individual tracks.
        // CRITICAL: addToNative must be TRUE (default) so the native renderer
        // (used by RTCVideoView) actually receives the track and can display it.
        // addToNative:false only adds the track to the Dart-side object, which
        // RTCVideoView ignores — causing a permanent black screen.
        debugPrint('📊 Remote track fallback: kind=${event.track.kind}');
        remoteStream ??= await createLocalMediaStream('remote_fallback');
        final hasTrack =
            remoteStream!.getTracks().any((track) => track.id == event.track.id);
        if (!hasTrack) {
          await remoteStream!.addTrack(event.track); // addToNative: true (default)
        }
        debugPrint('📊 Remote fallback stream: id=${remoteStream!.id}, '
            'audio=${remoteStream!.getAudioTracks().length}, '
            'video=${remoteStream!.getVideoTracks().length}');

        // Only fire once we have at least a video track in the fallback stream
        // (otherwise we'd fire on the audio track before video is added).
        final hasVideo = remoteStream!.getVideoTracks().isNotEmpty;
        if (hasVideo && remoteStream!.id != _lastRemoteStreamId) {
          _lastRemoteStreamId = remoteStream!.id;
          debugPrint('🆕 VideoCall: NEW fallback remote stream — forwarding to renderer');
          onRemoteStream(remoteStream!);
        }
      }
    };

    // Legacy compatibility: some web-based peers (e.g. doctor's browser portal)
    // still use peerConnection.addStream() which fires onAddStream on the remote
    // side instead of onTrack.  Handle both so we never miss the remote video.
    peerConnection!.onAddStream = (MediaStream stream) {
      debugPrint('═══════════════════════════════════════════════');
      debugPrint('📺 VideoCall: REMOTE STREAM via onAddStream');
      debugPrint('═══════════════════════════════════════════════');
      debugPrint('📊 Stream: id=${stream.id}, '
          'audio=${stream.getAudioTracks().length}, '
          'video=${stream.getVideoTracks().length}');
      remoteStream = stream;

      // DEDUP: if onTrack already forwarded this stream, skip to avoid a
      // second EglRenderer release+reinit cycle that blacks out the video.
      if (stream.id != _lastRemoteStreamId) {
        _lastRemoteStreamId = stream.id;
        debugPrint('🆕 VideoCall: NEW stream via onAddStream — forwarding to renderer');
        onRemoteStream(stream);
      } else {
        debugPrint('♻️  VideoCall: onAddStream duplicate (${stream.id}) — skipping');
      }
    };

    peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      debugPrint('🧊 VideoCall: sending ICE candidate');
      _socket?.emit('message', {
        'type': 'candidate',
        'candidate': {
          'candidate': candidate.candidate,
          'sdpMLineIndex': candidate.sdpMLineIndex,
          'sdpMid': candidate.sdpMid,
        },
        'roomId': _roomId,
      });
    };

    peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
      debugPrint('🧊 VideoCall: ICE connection state = $state');
    };

    peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
      debugPrint('📶 VideoCall: peer connection state = $state');
    };

    peerConnection!.onSignalingState = (RTCSignalingState state) {
      debugPrint('📡 VideoCall: signaling state = $state');
    };

    debugPrint('✅ VideoCall: peer connection setup complete');
  }

  /// Step 4 in RN: addLocalStream(stream)
  Future<void> addLocalStream(MediaStream stream) async {
    debugPrint('➕ VideoCall: adding local stream to peer connection...');
    localStream = stream;
    for (final track in stream.getTracks()) {
      await peerConnection?.addTrack(track, stream);
      debugPrint('   Added ${track.kind} track');
    }
    debugPrint('✅ VideoCall: local stream added');
  }

  // ═══════════════════════════════════════════════════════
  // 3. ROOM MANAGEMENT
  // ═══════════════════════════════════════════════════════

  /// Step 5 in RN: emitUserJoining (before joinRoom)
  void emitUserJoining({
    required String roomId,
    String? consultationId,
    String? doctorId,
    String? patientId,
    String? choId,           // CHO ID — backend uses this to generate FCM URL
    String userType = 'patient',
  }) {
    debugPrint('📤 VideoCall: emitting user_joining for room=$roomId choId=$choId');
    _socket?.emit('user_joining', {
      'roomId': roomId,
      'room_id': roomId,
      'consultId': consultationId ?? roomId,
      'consult_id': consultationId ?? roomId,
      'consultationId': consultationId ?? roomId,
      'consultation_id': consultationId ?? roomId,
      'doctorId': doctorId,
      'doctor_id': doctorId,
      'patientId': patientId,
      'patient_id': patientId,
      'choId': choId,
      'cho_id': choId,
      'userType': userType,
      'user_type': userType,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  // Stored so reconnect handler can rejoin automatically, matching the
  // reference app's plain-string joinRoom contract.
  String? _lastJoinRoomId;

  /// Step 6 in RN: joinRoom(roomId, callback)
  ///
  /// The reference app emits the plain roomId string to the server.
  void joinRoom({
    required String roomId,
    String? consultationId,
    String? doctorId,
    String? patientId,
    String userType = 'patient',
    String? userName,
    required void Function(String? error, Map<String, dynamic>? data) callback,
  }) {
    _roomId = roomId;
    _onRoomJoined = callback;
    _joinFallbackTimer?.cancel();
    _lastJoinRoomId = roomId;

    debugPrint('🚪 VideoCall: joining room=$roomId payload=<roomId string>');

    _socket?.emit('joinRoom', roomId);
  }

  /// Step 7a in RN: sendReady()
  void sendReady() {
    debugPrint('📤 VideoCall: sending ready signal for room=$_roomId');
    _socket?.emit('message', {
      'type': 'ready',
      'roomId': _roomId,
    });
  }

  /// Step 7b in RN: createOffer() — PUBLIC so hook can call it
  Future<void> createOffer() async {
    if (peerConnection == null) return;

    final sigState = peerConnection!.signalingState;
    debugPrint('📡 VideoCall: createOffer (signalingState=$sigState)');

    // null = platform hasn't reported state yet (flutter_webrtc quirk) → treat as stable
    if (sigState != null && sigState != RTCSignalingState.RTCSignalingStateStable) {
      debugPrint('⏳ VideoCall: skipping offer, not stable ($sigState)');
      return;
    }

    try {
      final offer = await peerConnection!.createOffer();
      await peerConnection!.setLocalDescription(offer);
      _socket?.emit('message', {
        'type': 'offer',
        'sdp': offer.sdp,
        'roomId': _roomId,
      });
      debugPrint('📤 VideoCall: offer sent');
    } catch (e) {
      debugPrint('❌ VideoCall: createOffer error: $e');
    }
  }

  /// Leave room
  void leaveRoom() {
    if (_roomId != null) {
      debugPrint('🚪 VideoCall: leaving room=$_roomId');
      _socket?.emit('leaveRoom', _roomId);
    }
  }

  // ═══════════════════════════════════════════════════════
  // 4. SIGNALING HANDLERS (internal)
  // ═══════════════════════════════════════════════════════

  Future<void> _handleOffer(Map<String, dynamic> msg) async {
    if (peerConnection == null) return;
    try {
      final sdp = msg['sdp'] as String?;
      if (sdp == null) {
        debugPrint('⚠️ VideoCall: offer missing SDP');
        return;
      }
      debugPrint('📥 VideoCall: handling offer...');
      await peerConnection!.setRemoteDescription(
        RTCSessionDescription(sdp, 'offer'),
      );
      await _flushPendingRemoteCandidates();
      final answer = await peerConnection!.createAnswer();
      await peerConnection!.setLocalDescription(answer);
      _socket?.emit('message', {
        'type': 'answer',
        'sdp': answer.sdp,
        'roomId': _roomId,
      });
      debugPrint('📤 VideoCall: answer sent automatically');
    } catch (e) {
      debugPrint('❌ VideoCall: handleOffer error: $e');
    }
  }

  Future<void> _handleAnswer(Map<String, dynamic> msg) async {
    if (peerConnection == null) return;
    try {
      final sdp = msg['sdp'] as String?;
      if (sdp == null) {
        debugPrint('⚠️ VideoCall: answer missing SDP');
        return;
      }
      debugPrint('📥 VideoCall: handling answer...');
      await peerConnection!.setRemoteDescription(
        RTCSessionDescription(sdp, 'answer'),
      );
      await _flushPendingRemoteCandidates();
      debugPrint('✅ VideoCall: remote description set (answer)');
    } catch (e) {
      debugPrint('❌ VideoCall: handleAnswer error: $e');
    }
  }

  Future<void> _handleCandidate(Map<String, dynamic> msg) async {
    if (peerConnection == null) return;
    try {
      final c = msg['candidate'];
      if (c == null) return;
      final candidate = RTCIceCandidate(
        c['candidate'] as String?,
        c['sdpMid'] as String?,
        c['sdpMLineIndex'] as int?,
      );

      if (!await _hasRemoteDescription()) {
        _pendingRemoteCandidates.add(candidate);
        debugPrint(
          '📥 VideoCall: queued ICE candidate (remote description not set yet)',
        );
        return;
      }

      debugPrint('📥 VideoCall: adding ICE candidate...');
      await peerConnection!.addCandidate(candidate);
      debugPrint('✅ VideoCall: ICE candidate added');
    } catch (e) {
      debugPrint('❌ VideoCall: addCandidate error: $e');
    }
  }

  Future<bool> _hasRemoteDescription() async {
    if (peerConnection == null) return false;
    final description = await peerConnection!.getRemoteDescription();
    return description != null && (description.sdp?.isNotEmpty ?? false);
  }

  Future<void> _flushPendingRemoteCandidates() async {
    if (peerConnection == null || !await _hasRemoteDescription()) return;
    if (_pendingRemoteCandidates.isEmpty) return;

    debugPrint(
      '🧊 VideoCall: flushing ${_pendingRemoteCandidates.length} queued ICE candidates',
    );

    while (_pendingRemoteCandidates.isNotEmpty) {
      final candidate = _pendingRemoteCandidates.removeAt(0);
      try {
        await peerConnection!.addCandidate(candidate);
      } catch (e) {
        debugPrint('❌ VideoCall: queued candidate add failed: $e');
      }
    }
  }

  // ═══════════════════════════════════════════════════════
  // 5. MEDIA CONTROLS
  // ═══════════════════════════════════════════════════════

  void toggleAudio(bool enabled) {
    localStream?.getAudioTracks().forEach((t) {
      t.enabled = enabled;
      debugPrint('🎤 VideoCall: audio track enabled=$enabled');
    });
  }

  void toggleVideo(bool enabled) {
    localStream?.getVideoTracks().forEach((t) {
      t.enabled = enabled;
      debugPrint('📹 VideoCall: video track enabled=$enabled');
    });
  }

  Future<void> switchCamera() async {
    final videoTrack = localStream?.getVideoTracks().firstOrNull;
    if (videoTrack != null) {
      await Helper.switchCamera(videoTrack);
      debugPrint('🔄 VideoCall: camera switched');
    }
  }

  // ═══════════════════════════════════════════════════════
  // 5b. CHAT (matching RN videoCallService chat methods)
  // ═══════════════════════════════════════════════════════

  /// Register listener for incoming chat messages (matching RN onChatMessage)
  void onChatMessage(void Function(Map<String, dynamic>) callback) {
    chatMessageCallback = callback;
    debugPrint('✅ VideoCall: chat message listener registered');
  }

  /// Remove chat message listener (matching RN removeChatMessageListener)
  void removeChatMessageListener() {
    chatMessageCallback = null;
    debugPrint('🧹 VideoCall: chat message listener removed');
  }

  /// Send a chat message to the room (matching RN sendChatMessage)
  bool sendChatMessage(Map<String, dynamic> messageData) {
    if (_socket == null || !isConnected) {
      debugPrint('❌ VideoCall: cannot send chat - not connected');
      return false;
    }
    if (_roomId == null) {
      debugPrint('❌ VideoCall: cannot send chat - not in a room');
      return false;
    }
    debugPrint('💬 VideoCall: sending chat message to room=$_roomId');
    _socket!.emit('message', {
      'type': 'chat',
      ...messageData,
      'roomId': _roomId,
      'timestamp': messageData['timestamp'] ?? DateTime.now().toIso8601String(),
    });
    debugPrint('✅ VideoCall: chat message sent');
    return true;
  }

  /// Request chat history from server (matching RN getChatHistory)
  void getChatHistory(
    String roomId,
    void Function(dynamic error, List<dynamic>? messages) callback,
  ) {
    if (_socket == null || !isConnected) {
      debugPrint('⚠️ VideoCall: getChatHistory skipped - socket not connected');
      callback('Socket not connected', null);
      return;
    }
    try {
      debugPrint('💬 VideoCall: requesting chat history for room=$roomId');
      var responded = false;
      Timer? ackTimer;
      ackTimer = Timer(const Duration(seconds: 3), () {
        if (responded) return;
        responded = true;
        debugPrint('⚠️ VideoCall: getChatHistory ack timeout for room=$roomId');
        callback('getChatHistory timeout', null);
      });

      _socket!.emitWithAck('getChatHistory', roomId, ack: (response) {
        if (responded) return;
        responded = true;
        ackTimer?.cancel();
        debugPrint('💬 VideoCall: chat history ack type=${response.runtimeType}');
        if (response is Map && response['error'] != null) {
          callback(response['error'], null);
        } else if (response is List) {
          callback(null, response);
        } else {
          callback(null, []);
        }
      });
    } catch (e) {
      debugPrint('⚠️ VideoCall: getChatHistory error: $e');
      callback(e.toString(), null);
    }
  }

  // ═══════════════════════════════════════════════════════
  // 6. CLEANUP
  // ═══════════════════════════════════════════════════════

  /// Full disconnect + cleanup (matching RN endCall → leaveRoom + disconnect).
  /// Called when the user explicitly ends the call.
  void disconnect() {
    debugPrint('═══════════════════════════════════════════════');
    debugPrint('🛑 VideoCall: DISCONNECTING & CLEANUP');
    debugPrint('═══════════════════════════════════════════════');

    _joinFallbackTimer?.cancel();
    _joinFallbackTimer = null;
    _pendingRemoteCandidates.clear();
    _lastRemoteStreamId = null;
    leaveRoom();

    // Stop local stream tracks
    if (localStream != null) {
      for (final track in localStream!.getTracks()) {
        track.stop();
        debugPrint('   Stopped ${track.kind} track');
      }
      localStream?.dispose();
      localStream = null;
    }

    remoteStream?.dispose();
    remoteStream = null;

    peerConnection?.close();
    peerConnection = null;

    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _roomId = null;
    _onRoomJoined = null;
    _connectCompleter = null;

    debugPrint('✅ VideoCall: cleanup complete');
    debugPrint('═══════════════════════════════════════════════');
  }

  /// Soft cleanup — called by VideoConsultationPage.dispose().
  /// Only clears streams & peer connection.  Socket stays alive so
  /// the next VideoConsultationPage can reuse it (matching RN singleton behaviour).
  void dispose() {
    debugPrint('🧹 VideoCall: soft dispose (socket kept alive for reuse)');

    _joinFallbackTimer?.cancel();
    _joinFallbackTimer = null;
    _lastRemoteStreamId = null;
    leaveRoom();

    if (localStream != null) {
      for (final track in localStream!.getTracks()) {
        track.stop();
      }
      localStream?.dispose();
      localStream = null;
    }

    remoteStream?.dispose();
    remoteStream = null;

    peerConnection?.close();
    peerConnection = null;

    _roomId = null;
    _onRoomJoined = null;
    onMessageCallback = null;
    onWaitingNotification = null;
    chatMessageCallback = null;

    // NOTE: _socket is intentionally kept alive for the next call session.
  }
}

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// In-call chat panel matching the React Native ChatPanel.js pattern exactly.
/// Slides in from the right, 85% screen width (max 400px).
class ChatPanel extends StatefulWidget {
  final bool visible;
  final VoidCallback onClose;
  final List<Map<String, dynamic>> messages;
  final void Function(Map<String, dynamic>) onSendMessage;
  final void Function(Map<String, dynamic>) onSendDocument;
  final Future<void> Function(Map<String, dynamic>) onOpenDocument;
  final String currentUserRole; // 'patient' or 'doctor'
  final String currentUserName;
  final String? currentUserId;

  const ChatPanel({
    super.key,
    required this.visible,
    required this.onClose,
    required this.messages,
    required this.onSendMessage,
    required this.onSendDocument,
    required this.onOpenDocument,
    required this.currentUserRole,
    required this.currentUserName,
    this.currentUserId,
  });

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animCtrl;
  late final Animation<Offset> _slideAnim;

  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  bool _panelMounted = false;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      duration: const Duration(milliseconds: 250),
      vsync: this,
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(1.0, 0.0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut));

    if (widget.visible) {
      _panelMounted = true;
      _animCtrl.forward();
    }
  }

  @override
  void didUpdateWidget(ChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.visible && !oldWidget.visible) {
      _panelMounted = true;
      _animCtrl.forward();
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } else if (!widget.visible && oldWidget.visible) {
      _animCtrl.reverse().then((_) {
        if (mounted) setState(() => _panelMounted = false);
      });
    }

    // Auto-scroll when new messages arrive
    if (widget.messages.length > oldWidget.messages.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  void _scrollToBottom() {
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  void _sendMessage() {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    widget.onSendMessage({
      'type': 'text',
      'content': text,
      'sender': widget.currentUserRole,
      'senderName': widget.currentUserName,
      'timestamp': DateTime.now().toIso8601String(),
    });
    _textCtrl.clear();
  }

  Future<void> _pickDocument() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) return;

    widget.onSendDocument({
      'type': 'document',
      'fileName': file.name,
      'fileType': 'application/pdf',
      'fileSize': file.size,
      'fileContent': base64Encode(bytes),
      'sender': widget.currentUserRole,
      'senderId': widget.currentUserId,
      'senderName': widget.currentUserName,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_panelMounted) return const SizedBox.shrink();

    final sw = MediaQuery.of(context).size.width;
    final panelWidth = (sw * 0.85).clamp(0.0, 400.0);

    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      width: panelWidth,
      child: SlideTransition(
        position: _slideAnim,
        child: Material(
          color: Colors.transparent,
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0xFF1A1A2E),
              boxShadow: [
                BoxShadow(
                  color: Colors.black54,
                  blurRadius: 20,
                  offset: Offset(-5, 0),
                )
              ],
            ),
            child: Column(
              children: [
                _buildHeader(context),
                Expanded(child: _buildMessageList()),
                _buildInput(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Header ───────────────────────────────────────────────

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
          16, MediaQuery.of(context).padding.top + 12, 8, 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.chat_bubble_outline_rounded,
              color: Colors.white70, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Chat',
              style: GoogleFonts.poppins(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Colors.white),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded,
                color: Colors.white60, size: 20),
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  // ── Message list ─────────────────────────────────────────

  Widget _buildMessageList() {
    if (widget.messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline_rounded,
                color: Colors.white.withValues(alpha: 0.2), size: 40),
            const SizedBox(height: 12),
            Text('No messages yet',
                style: GoogleFonts.inter(fontSize: 13, color: Colors.white30)),
          ],
        ),
      );
    }
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.all(12),
      itemCount: widget.messages.length,
      itemBuilder: (_, i) => _buildMessage(widget.messages[i]),
    );
  }

  Widget _buildMessage(Map<String, dynamic> msg) {
    final sender = msg['sender'] as String? ?? '';
    final isMe = sender == widget.currentUserRole;
    final content = msg['content'] as String? ?? '';
    final senderName = msg['senderName'] as String? ?? '';
    final timestamp = msg['timestamp'] as String? ?? '';
    final type = msg['type'] as String? ?? 'text';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Sender name for incoming messages
          if (!isMe && senderName.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 2),
              child: Text(
                senderName,
                style: GoogleFonts.inter(fontSize: 11, color: Colors.white38),
              ),
            ),

          // Message bubble
          Container(
            constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.65),
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: isMe
                  ? const Color(0xFF10B981)
                  : Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(18),
                topRight: const Radius.circular(18),
                bottomLeft: Radius.circular(isMe ? 18 : 4),
                bottomRight: Radius.circular(isMe ? 4 : 18),
              ),
            ),
            child: type == 'document'
                ? _buildDocumentBubble(msg)
                : Text(
                    content,
                    style: GoogleFonts.inter(
                        fontSize: 13, color: Colors.white, height: 1.4),
                  ),
          ),

          // Timestamp
          if (timestamp.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 4, right: 4),
              child: Text(
                _formatTime(timestamp),
                style:
                    GoogleFonts.inter(fontSize: 10, color: Colors.white24),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDocumentBubble(Map<String, dynamic> msg) {
    final fileName = msg['fileName'] as String? ?? 'Document';
    final fileType = msg['fileType'] as String? ?? '';
    final isImage = fileType.startsWith('image/');
    return InkWell(
      onTap: () => widget.onOpenDocument(msg),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isImage ? Icons.image_rounded : Icons.insert_drive_file_rounded,
            color: Colors.white,
            size: 20,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              fileName,
              style: GoogleFonts.inter(
                  fontSize: 13,
                  color: Colors.white,
                  decoration: TextDecoration.underline),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // ── Input ────────────────────────────────────────────────

  Widget _buildInput(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
          12, 8, 12, MediaQuery.of(context).padding.bottom + 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: _pickDocument,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.attach_file_rounded,
                  color: Colors.white, size: 18),
            ),
          ),
          const SizedBox(width: 8),
          // Text field
          Expanded(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.15)),
              ),
              child: TextField(
                controller: _textCtrl,
                style: GoogleFonts.inter(fontSize: 13, color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Type a message...',
                  hintStyle: GoogleFonts.inter(
                      fontSize: 13, color: Colors.white38),
                  isDense: true,
                  border: InputBorder.none,
                ),
                maxLength: 500,
                buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                onSubmitted: (_) => _sendMessage(),
                textInputAction: TextInputAction.send,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Send button
          GestureDetector(
            onTap: _sendMessage,
            child: Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                color: Color(0xFF10B981),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.send_rounded,
                  color: Colors.white, size: 18),
            ),
          ),
        ],
      ),
    );
  }

  // ── Helpers ──────────────────────────────────────────────

  String _formatTime(String timestamp) {
    try {
      final dt = DateTime.parse(timestamp).toLocal();
      final h = dt.hour.toString().padLeft(2, '0');
      final m = dt.minute.toString().padLeft(2, '0');
      return '$h:$m';
    } catch (_) {
      return '';
    }
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/doctor_model.dart';
import '../services/api_service.dart';
import '../services/booking_service.dart';
import '../utils/constants.dart';
import 'video_consultation_page.dart';

/// Shows a list of doctors with status filters (All, Online, Busy, Offline).
class TelemedicinePage extends StatefulWidget {
  final dynamic patientId;
  final String? patientName;
  final String? patientAbhaId;
  final String? initialFilter;

  const TelemedicinePage({
    super.key,
    this.patientId,
    this.patientName,
    this.patientAbhaId,
    this.initialFilter,
  });

  @override
  State<TelemedicinePage> createState() => _TelemedicinePageState();
}

class _TelemedicinePageState extends State<TelemedicinePage> {
  List<Doctor> _allDoctors = [];
  bool _isLoading = true;
  String? _errorMessage;
  String _filter = 'All';

  @override
  void initState() {
    super.initState();
    if (widget.initialFilter != null &&
        ['All', 'Online', 'Busy', 'Offline'].contains(widget.initialFilter)) {
      _filter = widget.initialFilter!;
    }
    _loadDoctors();
  }

  Future<void> _loadDoctors() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final doctors = await BookingService.getDoctors();
      if (!mounted) return;
      setState(() {
        _allDoctors = doctors;
        _isLoading = false;
      });
    } on BookingApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.message;
      });
    } catch (e) {
      debugPrint('❌ getDoctors error: $e');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to load doctors: $e';
      });
    }
  }

  List<Doctor> get _filtered {
    switch (_filter) {
      case 'Online':
        return _allDoctors.where((d) => d.isOnline).toList();
      case 'Busy':
        return _allDoctors.where((d) => d.isBusy).toList();
      case 'Offline':
        return _allDoctors.where((d) => d.isOffline).toList();
      default:
        return _allDoctors;
    }
  }

  int _count(String s) {
    switch (s) {
      case 'Online':
        return _allDoctors.where((d) => d.isOnline).length;
      case 'Busy':
        return _allDoctors.where((d) => d.isBusy).length;
      case 'Offline':
        return _allDoctors.where((d) => d.isOffline).length;
      default:
        return _allDoctors.length;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              size: 18, color: Colors.white),
        ),
        title: Text(
          widget.patientName != null ? 'Choose Doctor' : 'Doctors List',
          style: GoogleFonts.poppins(
              fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white),
        ),
        actions: [
          IconButton(
            onPressed: _loadDoctors,
            icon: const Icon(Icons.refresh_rounded,
                size: 20, color: Colors.white),
          ),
        ],
      ),
      body: Column(
        children: [
          // ─── Patient context banner ────────────────────
          if (widget.patientName != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: const Color(0xFFE3F2FD),
              child: Row(
                children: [
                  const Icon(Icons.person_rounded,
                      size: 15, color: Color(0xFF1565C0)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Patient: ${widget.patientName}',
                      style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF1565C0)),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),

          // ─── Filter Tabs ───────────────────────────────
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: ['All', 'Online', 'Busy', 'Offline'].map((s) {
                final sel = _filter == s;
                final c = _count(s);
                return Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _filter = s),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color:
                            sel ? AppColors.primary : const Color(0xFFF5F7FA),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (s != 'All') ...[
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: sel ? Colors.white : _dotColor(s),
                              ),
                            ),
                            const SizedBox(width: 4),
                          ],
                          Text(
                            '$s $c',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color:
                                  sel ? Colors.white : AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const Divider(height: 1, color: Color(0xFFEEEEEE)),

          // ─── Doctor List ───────────────────────────────
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.primary))
                : _errorMessage != null
                    ? _buildError()
                    : _filtered.isEmpty
                        ? _buildEmpty()
                        : RefreshIndicator(
                            onRefresh: _loadDoctors,
                            color: AppColors.primary,
                            child: ListView.builder(
                              padding:
                                  const EdgeInsets.fromLTRB(14, 10, 14, 20),
                              itemCount: _filtered.length,
                              itemBuilder: (_, i) =>
                                  _buildDoctorCard(_filtered[i]),
                            ),
                          ),
          ),
        ],
      ),
    );
  }

  // ── Doctor Card ─────────────────────────────────────────
  Widget _buildDoctorCard(Doctor doc) {
    return GestureDetector(
      onTap: () => _openDetail(doc),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE8ECF0)),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.025),
                blurRadius: 8,
                offset: const Offset(0, 2)),
          ],
        ),
        child: Row(
          children: [
            // Avatar with status dot
            Stack(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Center(
                    child: Text(
                      doc.initials,
                      style: GoogleFonts.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primary),
                    ),
                  ),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _dotColor(doc.status),
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 10),

            // Name + Specialization + City
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    doc.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  if (doc.specialization != null)
                    Text(
                      doc.specialization!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                          fontSize: 11.5, color: AppColors.textSecondary),
                    ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (doc.city != null) ...[
                        Icon(Icons.location_on_outlined,
                            size: 11, color: AppColors.textHint),
                        const SizedBox(width: 2),
                        Text(
                          doc.city!,
                          style: GoogleFonts.inter(
                              fontSize: 10.5, color: AppColors.textHint),
                        ),
                        const SizedBox(width: 8),
                      ],
                      if (doc.hprId != null) ...[
                        Icon(Icons.badge_outlined,
                            size: 11, color: AppColors.textHint),
                        const SizedBox(width: 2),
                        Flexible(
                          child: Text(
                            doc.hprId!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                                fontSize: 10.5, color: AppColors.textHint),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),

            // Status + Consult button
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _buildStatusChip(doc.status),
                if (doc.isOnline) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF4CAF50),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.videocam_rounded,
                            size: 12, color: Colors.white),
                        const SizedBox(width: 3),
                        Text('Consult',
                            style: GoogleFonts.inter(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: Colors.white)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChip(String status) {
    Color bg, fg;
    String label;
    switch (status) {
      case 'online':
        bg = const Color(0xFFE8F5E9);
        fg = const Color(0xFF2E7D32);
        label = 'Online';
        break;
      case 'busy':
        bg = const Color(0xFFFFF3E0);
        fg = const Color(0xFFE65100);
        label = 'Busy';
        break;
      default:
        bg = const Color(0xFFF5F5F5);
        fg = const Color(0xFF757575);
        label = 'Offline';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(label,
          style: GoogleFonts.inter(
              fontSize: 10, fontWeight: FontWeight.w600, color: fg)),
    );
  }

  // ── Error / Empty states ────────────────────────────────
  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 40, color: AppColors.error.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text(_errorMessage!,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                    fontSize: 13, color: AppColors.textSecondary)),
            const SizedBox(height: 8),
            Text(
              'If the list is empty unexpectedly, refresh once after login is restored.',
              textAlign: TextAlign.center,
              style:
                  GoogleFonts.inter(fontSize: 11.5, color: AppColors.textHint),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _loadDoctors,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.person_search_rounded,
                size: 40, color: AppColors.textHint.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text(
              'No ${_filter == 'All' ? '' : '${_filter.toLowerCase()} '}doctors found',
              style: GoogleFonts.inter(
                  fontSize: 13, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  void _openDetail(Doctor doctor) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _DoctorDetailPage(
          doctor: doctor,
          patientId: widget.patientId,
          patientName: widget.patientName,
          patientAbhaId: widget.patientAbhaId,
        ),
      ),
    );
  }

  static Color _dotColor(String status) {
    switch (status.toLowerCase()) {
      case 'online':
        return const Color(0xFF4CAF50);
      case 'busy':
        return const Color(0xFFFF9800);
      default:
        return const Color(0xFFBDBDBD);
    }
  }
}

// ═══════════════════════════════════════════════════════════
// DOCTOR DETAIL PAGE
// ═══════════════════════════════════════════════════════════
class _DoctorDetailPage extends StatefulWidget {
  final Doctor doctor;
  final dynamic patientId;
  final String? patientName;
  final String? patientAbhaId;

  const _DoctorDetailPage({
    required this.doctor,
    this.patientId,
    this.patientName,
    this.patientAbhaId,
  });

  @override
  State<_DoctorDetailPage> createState() => _DoctorDetailPageState();
}

class _DoctorDetailPageState extends State<_DoctorDetailPage> {
  Doctor? _detail;
  bool _isLoading = true;
  bool _isLaunchingConsultation = false;

  int get _resolvedPatientId {
    if (widget.patientId is int) return widget.patientId as int;
    return int.tryParse(widget.patientId?.toString() ?? '') ?? 0;
  }

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    try {
      final d = await BookingService.getDoctorById(widget.doctor.id);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _detail = widget.doctor;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final doc = _detail ?? widget.doctor;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary))
          : CustomScrollView(
              slivers: [
                SliverAppBar(
                  pinned: true,
                  expandedHeight: 210,
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  flexibleSpace: FlexibleSpaceBar(
                    background: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            AppColors.primary,
                            const Color(0xFF1E56AF),
                            const Color(0xFF173D84),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color:
                                const Color(0xFF12326A).withValues(alpha: 0.18),
                            blurRadius: 24,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Container(
                                    width: 62,
                                    height: 62,
                                    decoration: BoxDecoration(
                                      color:
                                          Colors.white.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(18),
                                      border: Border.all(
                                        color: Colors.white
                                            .withValues(alpha: 0.14),
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black
                                              .withValues(alpha: 0.12),
                                          blurRadius: 16,
                                          offset: const Offset(0, 8),
                                        ),
                                      ],
                                    ),
                                    child: Center(
                                      child: Text(
                                        doc.initials,
                                        style: GoogleFonts.poppins(
                                            fontSize: 22,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.white),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          doc.name,
                                          style: GoogleFonts.poppins(
                                              fontSize: 18,
                                              fontWeight: FontWeight.w700,
                                              color: Colors.white),
                                        ),
                                        if (doc.specialization != null) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            doc.specialization!,
                                            style: GoogleFonts.dmSans(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w500,
                                                color: Colors.white
                                                    .withValues(alpha: 0.82)),
                                          ),
                                        ],
                                        const SizedBox(height: 8),
                                        Wrap(
                                          spacing: 6,
                                          runSpacing: 6,
                                          children: [
                                            _headerChip(
                                                doc.isOnline
                                                    ? 'Online'
                                                    : doc.isBusy
                                                        ? 'Busy'
                                                        : 'Offline',
                                                _dotColorStatic(doc.status)),
                                            if (doc.city != null)
                                              _headerChip(doc.city!, null),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 22),
                    child: Column(
                      children: [
                        _card(
                          icon: Icons.badge_outlined,
                          title: 'Doctor Information',
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final width = constraints.maxWidth;
                              final itemWidth =
                                  width > 620 ? (width - 10) / 2 : width;
                              return Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  if (doc.phone != null)
                                    SizedBox(
                                      width: itemWidth,
                                      child: _infoTile(
                                        icon: Icons.phone_outlined,
                                        label: 'Phone',
                                        value: doc.phone!,
                                      ),
                                    ),
                                  if (doc.email != null)
                                    SizedBox(
                                      width: itemWidth,
                                      child: _infoTile(
                                        icon: Icons.email_outlined,
                                        label: 'Email',
                                        value: doc.email!,
                                      ),
                                    ),
                                  if (doc.gender != null)
                                    SizedBox(
                                      width: itemWidth,
                                      child: _infoTile(
                                        icon: Icons.wc_outlined,
                                        label: 'Gender',
                                        value: doc.gender!
                                                .substring(0, 1)
                                                .toUpperCase() +
                                            doc.gender!.substring(1),
                                      ),
                                    ),
                                  if (doc.city != null)
                                    SizedBox(
                                      width: itemWidth,
                                      child: _infoTile(
                                        icon: Icons.location_on_outlined,
                                        label: 'City',
                                        value: doc.city!,
                                      ),
                                    ),
                                  if (doc.hprId != null)
                                    SizedBox(
                                      width: itemWidth,
                                      child: _infoTile(
                                        icon: Icons.badge_outlined,
                                        label: 'HPR ID',
                                        value: doc.hprId!,
                                      ),
                                    ),
                                  if (doc.qualification != null)
                                    SizedBox(
                                      width: itemWidth,
                                      child: _infoTile(
                                        icon: Icons.school_outlined,
                                        label: 'Qualification',
                                        value: doc.qualification!,
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 10),
                        _card(
                          icon: Icons.videocam_outlined,
                          title: 'Telemedicine Service',
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF4FBF7),
                              borderRadius: BorderRadius.circular(14),
                              border:
                                  Border.all(color: const Color(0xFFD7EFD9)),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 34,
                                  height: 34,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE5F6EA),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Icon(
                                    Icons.videocam_rounded,
                                    size: 16,
                                    color: Color(0xFF2E7D32),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'Video consultation available for this doctor.',
                                    style: GoogleFonts.inter(
                                      fontSize: 11.5,
                                      height: 1.35,
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        _card(
                          icon: Icons.medical_services_outlined,
                          title: 'Consultation Status',
                          child: Column(
                            children: [
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: doc.isOnline
                                      ? const Color(0xFFF0FFF4)
                                      : doc.isBusy
                                          ? const Color(0xFFFFF8E1)
                                          : const Color(0xFFF5F5F5),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: doc.isOnline
                                        ? const Color(0xFFCFE8D2)
                                        : doc.isBusy
                                            ? const Color(0xFFFFE0B2)
                                            : const Color(0xFFE2E5E9),
                                  ),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      width: 10,
                                      height: 10,
                                      margin: const EdgeInsets.only(top: 3),
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: _dotColorStatic(doc.status),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        doc.isOnline
                                            ? 'Doctor is available for consultation right now.'
                                            : doc.isBusy
                                                ? 'Doctor is currently attending another consultation.'
                                                : 'Doctor is currently offline for consultation.',
                                        style: GoogleFonts.dmSans(
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w700,
                                          color: doc.isOnline
                                              ? const Color(0xFF2E7D32)
                                              : doc.isBusy
                                                  ? const Color(0xFFE65100)
                                                  : const Color(0xFF757575),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (doc.isOnline) ...[
                                const SizedBox(height: 12),
                                if (_resolvedPatientId <= 0) ...[
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(10),
                                    margin: const EdgeInsets.only(bottom: 10),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFFF8E1),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                          color: const Color(0xFFFFE082)),
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.info_outline,
                                            size: 15, color: Color(0xFFF57F17)),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            'Patient ID is missing for this consultation. Open telemedicine from a verified patient appointment.',
                                            style: GoogleFonts.inter(
                                                fontSize: 10.5,
                                                height: 1.3,
                                                color: const Color(0xFFF57F17)),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                                SizedBox(
                                  width: double.infinity,
                                  height: 46,
                                  child: ElevatedButton.icon(
                                    onPressed: _resolvedPatientId > 0
                                        ? () => _startConsultation(doc)
                                        : null,
                                    icon: const Icon(Icons.videocam_rounded,
                                        size: 18),
                                    label: Text(
                                      'Start Video Consultation',
                                      style: GoogleFonts.dmSans(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF3FB24F),
                                      foregroundColor: Colors.white,
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12)),
                                    ),
                                  ),
                                ),
                              ],
                              if (!doc.isOnline) ...[
                                const SizedBox(height: 10),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFF8E1),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                        color: const Color(0xFFFFE082)),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.info_outline,
                                          size: 15, color: Color(0xFFF57F17)),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          doc.isBusy
                                              ? 'Doctor is busy. Please try again shortly.'
                                              : 'Video consultation available when doctor is online.',
                                          style: GoogleFonts.inter(
                                              fontSize: 10.5,
                                              height: 1.3,
                                              color: const Color(0xFFF57F17)),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  // ── Reusable card wrapper ───────────────────────────────
  Widget _card(
      {required IconData icon, required String title, required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE5EAF1)),
        boxShadow: [
          BoxShadow(
              color: const Color(0xFF0F172A).withValues(alpha: 0.04),
              blurRadius: 16,
              offset: const Offset(0, 6)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: const Color(0xFFEAF2FF),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 15, color: AppColors.primary),
              ),
              const SizedBox(width: 8),
              Text(title,
                  style: GoogleFonts.dmSans(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary)),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _infoTile({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9FC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE7ECF2)),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 15, color: AppColors.primary),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    color: AppColors.textHint,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: GoogleFonts.dmSans(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerChip(String text, Color? dotColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dotColor != null) ...[
            Container(
                width: 7,
                height: 7,
                decoration:
                    BoxDecoration(shape: BoxShape.circle, color: dotColor)),
            const SizedBox(width: 5),
          ],
          Text(text,
              style: GoogleFonts.dmSans(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: Colors.white)),
        ],
      ),
    );
  }

  // ── Consultation Flow ───────────────────────────────────
  void _startConsultation(Doctor doc) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            const Icon(Icons.video_call_rounded,
                color: Color(0xFF2E7D32), size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Request Consultation',
                  style: GoogleFonts.poppins(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        content: Text(
          'Send a consultation request to ${doc.name}?'
          '\n\nThe doctor will be notified and must accept before the call begins.'
          '${widget.patientName != null ? '\n\nPatient: ${widget.patientName}' : ''}',
          style: GoogleFonts.inter(
              fontSize: 13, height: 1.4, color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: GoogleFonts.inter(fontSize: 13)),
          ),
          ElevatedButton.icon(
            onPressed: _isLaunchingConsultation
                ? null
                : () {
                    Navigator.pop(ctx);
                    _launchConsultation(doc);
                  },
            icon: _isLaunchingConsultation
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.send_rounded, size: 16),
            label: Text(
              _isLaunchingConsultation ? 'Starting...' : 'Request',
              style:
                  GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4CAF50),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _launchConsultation(Doctor doc) async {
    if (!mounted) return;

    final patId = _resolvedPatientId;

    if (patId <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Patient ID is missing for this consultation. Open telemedicine from a verified patient appointment.',
          ),
        ),
      );
      return;
    }

    if (_isLaunchingConsultation) return;

    setState(() => _isLaunchingConsultation = true);
    try {
      debugPrint(
          '📞 Telemedicine: opening consultation flow for doctor=${doc.id} patient=$patId');
      try {
        final choId = await ApiService.getChoId();
        debugPrint('🆔 Telemedicine: CHO ID=$choId');
        final accessData = await BookingService.grantPatientAccess(
          doctorId: doc.id,
          patientId: patId,
        );
        debugPrint('✅ Telemedicine: patient access granted: $accessData');
      } catch (e) {
        debugPrint('⚠️ Telemedicine: grantPatientAccess failed: $e');
      }

      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VideoConsultationPage(
            doctorId: doc.id,
            doctorName: doc.name,
            patientId: patId,
            patientName: widget.patientName,
            patientAbhaId: widget.patientAbhaId,
            roomId: null,
            skipConsent: false,
            autoRequestConsent: true,
          ),
        ),
      );
    } catch (e) {
      debugPrint('❌ Telemedicine: failed to launch consultation: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to start consultation: $e'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isLaunchingConsultation = false);
      }
    }
  }

  static Color _dotColorStatic(String status) {
    switch (status) {
      case 'online':
        return const Color(0xFF4CAF50);
      case 'busy':
        return const Color(0xFFFF9800);
      default:
        return const Color(0xFFBDBDBD);
    }
  }
}

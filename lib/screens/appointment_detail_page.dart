import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../models/appointment_model.dart';
import '../utils/constants.dart';
import 'telemedicine_page.dart';

class AppointmentDetailPage extends StatelessWidget {
  const AppointmentDetailPage({super.key, required this.appointment});

  final Appointment appointment;

  @override
  Widget build(BuildContext context) {
    final detailRows = _buildDetailRows();
    final extraRows = _buildAdditionalRows();

    return Scaffold(
      backgroundColor: const Color(0xFFF5F8FA),
      bottomNavigationBar: _TelemedicineBottomBar(appointment: appointment),
      body: CustomScrollView(
        slivers: [
          // ── SLIVER APP BAR ──
          SliverAppBar(
            pinned: true,
            expandedHeight: 230,
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration:
                    const BoxDecoration(gradient: AppColors.headerGradient),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Container(
                          width: 76,
                          height: 76,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.16),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.18),
                              width: 2,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              appointment.initials,
                              style: GoogleFonts.poppins(
                                fontSize: 28,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          appointment.patientName ?? 'Unknown Patient',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.poppins(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _HeroChip(
                              label: appointment.status?.toUpperCase() ??
                                  'PENDING',
                            ),
                            if (appointment.tokenNumber?.isNotEmpty == true)
                              _HeroChip(
                                  label: 'Token ${appointment.tokenNumber}'),
                            if (appointment.appointmentType?.isNotEmpty == true)
                              _HeroChip(label: appointment.appointmentType!),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // ── BODY ──
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
              child: Column(
                children: [
                  // ══ 1. APPOINTMENT OVERVIEW ══
                  _SectionCard(
                    title: 'Appointment Overview',
                    icon: Icons.calendar_month_rounded,
                    child: _buildOverviewGrid(context),
                  ),
                  const SizedBox(height: 14),

                  // ══ 2. PATIENT INFORMATION ══
                  if (detailRows.isNotEmpty)
                    _SectionCard(
                      title: 'Patient Information',
                      icon: Icons.person_outline_rounded,
                      child: Column(
                        children: detailRows
                            .map((row) =>
                                _DetailRow(label: row.$1, value: row.$2))
                            .toList(),
                      ),
                    ),
                  if (detailRows.isNotEmpty) const SizedBox(height: 14),

                  // ══ 3. CLINICAL SNAPSHOT ══
                  _SectionCard(
                    title: 'Clinical Snapshot',
                    icon: Icons.monitor_heart_outlined,
                    child: Column(
                      children: [
                        _buildVitalsGrid(context),
                        if (appointment.chiefComplaints?.trim().isNotEmpty ==
                            true) ...[
                          const SizedBox(height: 16),
                          _TextBlock(
                            label: 'Chief Complaints',
                            value: appointment.chiefComplaints!,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // ══ 4. VISIT NOTES ══
                  if (_hasVisitNotes())
                    _SectionCard(
                      title: 'Visit Notes',
                      icon: Icons.description_outlined,
                      child: Column(
                        children: [
                          if (appointment.reason?.trim().isNotEmpty == true)
                            _TextBlock(
                              label: 'Visit Reason',
                              value: appointment.reason!,
                            ),
                          if (appointment.reason?.trim().isNotEmpty == true &&
                              appointment.notes?.trim().isNotEmpty == true)
                            const SizedBox(height: 12),
                          if (appointment.notes?.trim().isNotEmpty == true)
                            _TextBlock(
                              label: 'Notes',
                              value: appointment.notes!,
                            ),
                        ],
                      ),
                    ),
                  if (_hasVisitNotes()) const SizedBox(height: 14),

                  // ══ 5. OBSERVATION HISTORY ══
                  if (appointment.previousObservations?.isNotEmpty == true) ...[
                    _SectionCard(
                      title: 'Observation History',
                      icon: Icons.history_rounded,
                      child: Column(
                        children: appointment.previousObservations!
                            .take(8)
                            .map(
                              (item) => _HistoryTile(
                                title: _stringValue(
                                  item['summary'] ??
                                      item['notes'] ??
                                      item['chief_complaints'] ??
                                      'Observation recorded',
                                ),
                                subtitle: _stringValue(
                                  item['date'] ??
                                      item['created_at'] ??
                                      item['updated_at'] ??
                                      '',
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],

                  // ══ 6. ADDITIONAL DATA ══
                  if (extraRows.isNotEmpty)
                    _SectionCard(
                      title: 'Additional Details',
                      icon: Icons.info_outline_rounded,
                      child: Column(
                        children: extraRows
                            .map((row) =>
                                _StackedDetailRow(label: row.$1, value: row.$2))
                            .toList(),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // OVERVIEW GRID (2 columns using Row + Expanded)
  // ═══════════════════════════════════════════════════════════
  Widget _buildOverviewGrid(BuildContext context) {
    final tiles = <_OverviewData>[
      if (appointment.appointmentDate != null)
        _OverviewData(
          'Date',
          _formatDate(appointment.appointmentDate),
          Icons.event_rounded,
        ),
      if (appointment.appointmentTime != null)
        _OverviewData(
          'Time',
          appointment.appointmentTime!,
          Icons.schedule_rounded,
        ),
      if (appointment.villageName != null)
        _OverviewData(
          'Village',
          appointment.villageName!,
          Icons.location_on_outlined,
        ),
      if (appointment.doctorName != null)
        _OverviewData(
          'Doctor',
          appointment.doctorName!,
          Icons.medical_services_outlined,
        ),
      if (appointment.subCenter != null)
        _OverviewData(
          'Sub Center',
          appointment.subCenter!,
          Icons.local_hospital_outlined,
        ),
      if (appointment.choName != null)
        _OverviewData(
          'CHO',
          appointment.choName!,
          Icons.badge_outlined,
        ),
    ];

    // Build rows of 2
    final rows = <Widget>[];
    for (int i = 0; i < tiles.length; i += 2) {
      final left = tiles[i];
      final right = (i + 1 < tiles.length) ? tiles[i + 1] : null;
      rows.add(
        Padding(
          padding: EdgeInsets.only(top: i > 0 ? 10 : 0),
          child: Row(
            children: [
              Expanded(
                child: _OverviewTile(
                    label: left.label, value: left.value, icon: left.icon),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: right != null
                    ? _OverviewTile(
                        label: right.label,
                        value: right.value,
                        icon: right.icon)
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      );
    }

    if (rows.isEmpty) {
      return Text(
        'No overview data available',
        style: GoogleFonts.inter(fontSize: 13, color: AppColors.textSecondary),
      );
    }
    return Column(children: rows);
  }

  // ═══════════════════════════════════════════════════════════
  // VITALS GRID (2 columns using Row + Expanded)
  // ═══════════════════════════════════════════════════════════
  Widget _buildVitalsGrid(BuildContext context) {
    final vitals = <_VitalData>[
      _VitalData(
        'SpO2',
        appointment.spo2 != null
            ? '${appointment.spo2!.toStringAsFixed(0)}%'
            : '—',
        Icons.air_rounded,
        const Color(0xFF2F80ED),
      ),
      _VitalData(
        'Temperature',
        appointment.temperature != null
            ? '${appointment.temperature!.toStringAsFixed(1)}°F'
            : '—',
        Icons.thermostat_rounded,
        const Color(0xFFEB5757),
      ),
      _VitalData(
        'Blood Pressure',
        appointment.bloodPressure ?? '—',
        Icons.favorite_rounded,
        const Color(0xFF9B51E0),
      ),
      _VitalData(
        'Weight',
        appointment.weight != null
            ? '${appointment.weight!.toStringAsFixed(1)} kg'
            : '—',
        Icons.monitor_weight_outlined,
        const Color(0xFFF2994A),
      ),
      _VitalData(
        'Height',
        appointment.height != null
            ? '${appointment.height!.toStringAsFixed(1)} cm'
            : '—',
        Icons.height_rounded,
        const Color(0xFF219653),
      ),
      _VitalData(
        'BMI',
        appointment.bmi != null ? appointment.bmi!.toStringAsFixed(1) : '—',
        Icons.calculate_outlined,
        AppColors.primaryDeep,
      ),
    ];

    // Build rows of 2
    final rows = <Widget>[];
    for (int i = 0; i < vitals.length; i += 2) {
      final left = vitals[i];
      final right = (i + 1 < vitals.length) ? vitals[i + 1] : null;
      rows.add(
        Padding(
          padding: EdgeInsets.only(top: i > 0 ? 10 : 0),
          child: Row(
            children: [
              Expanded(
                child: _VitalCard(
                  label: left.label,
                  value: left.value,
                  icon: left.icon,
                  color: left.color,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: right != null
                    ? _VitalCard(
                        label: right.label,
                        value: right.value,
                        icon: right.icon,
                        color: right.color,
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      );
    }
    return Column(children: rows);
  }

  // ═══════════════════════════════════════════════════════════
  // DATA BUILDERS
  // ═══════════════════════════════════════════════════════════
  bool _hasVisitNotes() {
    return (appointment.reason?.trim().isNotEmpty == true) ||
        (appointment.notes?.trim().isNotEmpty == true);
  }

  /// Build only non-null, meaningful patient detail rows.
  List<(String, String)> _buildDetailRows() {
    final rows = <(String, String)>[];

    void add(String label, String? value) {
      if (value != null && value.trim().isNotEmpty && value.trim() != '—') {
        rows.add((label, value.trim()));
      }
    }

    add('Phone', appointment.patientPhone);
    add('Email', appointment.patientEmail);
    if (appointment.age != null) add('Age', '${appointment.age} years');
    add('Gender', appointment.gender);
    add('ABHA ID', appointment.abhaId);
    add('Address', appointment.address);

    return rows;
  }

  /// Show ALL remaining data from rawData — flatten nested Maps/Lists
  /// into readable key-value pairs instead of raw JSON.
  List<(String, String)> _buildAdditionalRows() {
    final raw = appointment.rawData;
    if (raw == null || raw.isEmpty) return [];

    // Keys already displayed in other sections
    const hiddenKeys = {
      'id', 'appointment_id', 'patient_name', 'patientName', 'name',
      'patient_phone', 'patientPhone', 'phone', 'mobile',
      'patient_email', 'patientEmail', 'email',
      'appointment_date', 'appointmentDate', 'date',
      'appointment_time', 'appointmentTime', 'time',
      'status', 'reason', 'visit_reason', 'purpose',
      'doctor_name', 'doctorName',
      'village_name', 'villageName', 'village',
      'sub_center', 'subCenter',
      'cho_name', 'choName', 'cho_id', 'choId',
      'notes', 'remark', 'remarks',
      'created_at', 'createdAt', 'updated_at', 'updatedAt',
      'gender', 'age', 'address',
      'token_number', 'tokenNumber', 'token',
      'appointment_type', 'appointmentType', 'type',
      'abha_id', 'abhaId', 'ABHA_ID',
      'patient_id', 'patientId',
      'spo2', 'temperature', 'blood_pressure', 'bp',
      'height', 'weight', 'bmi',
      'chief_complaints', 'chiefComplaints',
      'previous_observations', 'observations',
    };

    final rows = <(String, String)>[];

    void addFlat(String prefix, dynamic value, {int depth = 0}) {
      if (value == null || depth > 3) return;

      if (value is Map) {
        value.forEach((k, v) {
          if (v == null) return;
          final childLabel = prefix.isEmpty
              ? _toLabel('$k')
              : '$prefix \u2022 ${_toLabel('$k')}';
          addFlat(childLabel, v, depth: depth + 1);
        });
      } else if (value is List) {
        if (value.isEmpty) return;
        if (value.every((e) => e is String || e is num || e is bool)) {
          final joined = value.map((e) => e.toString()).join(', ');
          if (joined.isNotEmpty && joined.length <= 300) {
            rows.add((prefix, joined));
          }
        } else {
          // For each map item in list, flatten its simple fields
          for (int i = 0; i < value.length && i < 5; i++) {
            final item = value[i];
            if (item is Map) {
              item.forEach((k, v) {
                if (v == null || v is Map || v is List) return;
                final str = v.toString().trim();
                if (str.isEmpty || str == 'null') return;
                rows.add(('$prefix [${i + 1}] \u2022 ${_toLabel('$k')}', str));
              });
            }
          }
        }
      } else {
        final str = value.toString().trim();
        if (str.isNotEmpty && str != 'null' && str.length <= 300) {
          rows.add((prefix, str));
        }
      }
    }

    raw.forEach((key, value) {
      if (hiddenKeys.contains(key) || value == null) return;
      addFlat(_toLabel(key), value);
    });

    return rows;
  }

  static String _formatDate(String? date) {
    if (date == null || date.isEmpty) return '—';
    try {
      return DateFormat('dd MMM yyyy').format(DateTime.parse(date));
    } catch (_) {
      return date;
    }
  }

  static String _toLabel(String key) {
    final withSpaces = key.replaceAll('_', ' ');
    return withSpaces
        .split(' ')
        .where((part) => part.isNotEmpty)
        .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
        .join(' ');
  }

  static String _stringValue(dynamic value) =>
      value?.toString().trim() ?? '';
}

// ═══════════════════════════════════════════════════════════
// DATA HOLDERS
// ═══════════════════════════════════════════════════════════
class _OverviewData {
  final String label;
  final String value;
  final IconData icon;
  const _OverviewData(this.label, this.value, this.icon);
}

class _VitalData {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  const _VitalData(this.label, this.value, this.icon, this.color);
}

// ═══════════════════════════════════════════════════════════
// SECTION CARD
// ═══════════════════════════════════════════════════════════
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.cardBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: AppColors.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Text(
                title,
                style: GoogleFonts.poppins(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// HERO CHIP (header badges)
// ═══════════════════════════════════════════════════════════
class _HeroChip extends StatelessWidget {
  const _HeroChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// OVERVIEW TILE (2-per-row, uses Expanded parent)
// ═══════════════════════════════════════════════════════════
class _OverviewTile extends StatelessWidget {
  const _OverviewTile({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FBFB),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.primary),
          const SizedBox(height: 10),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.poppins(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// DETAIL ROW
// ═══════════════════════════════════════════════════════════
class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: BoxDecoration(
        border: Border(
          bottom:
              BorderSide(color: AppColors.cardBorder.withValues(alpha: 0.75)),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118,
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: GoogleFonts.inter(
                fontSize: 13,
                height: 1.5,
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// STACKED DETAIL ROW (for Additional Details — label above, value below)
// ═══════════════════════════════════════════════════════════
class _StackedDetailRow extends StatelessWidget {
  const _StackedDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          bottom:
              BorderSide(color: AppColors.cardBorder.withValues(alpha: 0.6)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11,
              color: AppColors.textHint,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 13,
              height: 1.4,
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// VITAL CARD (2-per-row, uses Expanded parent)
// ═══════════════════════════════════════════════════════════
class _VitalCard extends StatelessWidget {
  const _VitalCard({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  final String label;
  final String value;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// TEXT BLOCK
// ═══════════════════════════════════════════════════════════
class _TextBlock extends StatelessWidget {
  const _TextBlock({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FBFB),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 12,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 13,
              height: 1.55,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// TELEMEDICINE BOTTOM BAR (fixed above system nav bar)
// ═══════════════════════════════════════════════════════════
class _TelemedicineBottomBar extends StatelessWidget {
  const _TelemedicineBottomBar({required this.appointment});

  final Appointment appointment;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Row(
            children: [
              // Browse Doctors button
              Expanded(
                child: _BottomBarButton(
                  icon: Icons.person_search_rounded,
                  label: 'Browse Doctors',
                  color: AppColors.primary,
                  filled: false,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => TelemedicinePage(
                          patientId: appointment.patientId,
                          patientName: appointment.patientName,
                          patientAbhaId: appointment.abhaId,
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 10),
              // Quick Consult button
              Expanded(
                child: _BottomBarButton(
                  icon: Icons.videocam_rounded,
                  label: 'Quick Consult',
                  color: const Color(0xFF4CAF50),
                  filled: true,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => TelemedicinePage(
                          patientId: appointment.patientId,
                          patientName: appointment.patientName,
                          patientAbhaId: appointment.abhaId,
                          initialFilter: 'Online',
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomBarButton extends StatelessWidget {
  const _BottomBarButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.filled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: filled ? color : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 46,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: filled ? null : Border.all(color: color, width: 1.5),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17, color: filled ? Colors.white : color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: filled ? Colors.white : color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// HISTORY TILE
// ═══════════════════════════════════════════════════════════
class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FBFB),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.only(top: 4),
            decoration: const BoxDecoration(
              color: AppColors.primary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color: AppColors.textHint,
                    ),
                  ),
                if (subtitle.isNotEmpty) const SizedBox(height: 4),
                Text(
                  title,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    height: 1.5,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

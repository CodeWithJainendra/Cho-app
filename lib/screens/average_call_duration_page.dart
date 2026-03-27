import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../models/appointment_model.dart';
import '../utils/constants.dart';

class AverageCallDurationPage extends StatelessWidget {
  const AverageCallDurationPage({
    super.key,
    required this.appointments,
    required this.userName,
  });

  final List<Appointment> appointments;
  final String userName;

  DateTime? _appointmentDate(Appointment appointment) {
    final rawDate = appointment.appointmentDate ?? appointment.createdAt;
    if (rawDate == null || rawDate.isEmpty) return null;
    try {
      return DateTime.parse(rawDate);
    } catch (_) {
      return null;
    }
  }

  int? _extractDurationMinutes(Appointment appointment) {
    final raw = appointment.rawData;
    if (raw == null) return null;

    final candidates = [
      raw['call_duration'],
      raw['callDuration'],
      raw['duration'],
      raw['duration_minutes'],
      raw['durationMinutes'],
      raw['consultation_duration'],
      raw['consultationDuration'],
      raw['minutes'],
      raw['call_minutes'],
      raw['callMinutes'],
    ];

    for (final value in candidates) {
      final parsed = _parseDurationValue(value);
      if (parsed != null) return parsed;
    }
    return null;
  }

  int? _parseDurationValue(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is double) return value.round();
    final match = RegExp(r'\d+').firstMatch(value.toString());
    return match == null ? null : int.tryParse(match.group(0)!);
  }

  @override
  Widget build(BuildContext context) {
    final records = appointments
        .map((appointment) {
          final duration = _extractDurationMinutes(appointment);
          final date = _appointmentDate(appointment);
          if (duration == null || duration <= 0 || date == null) return null;
          return _DurationRecord(
            appointment: appointment,
            durationMinutes: duration,
            date: date,
          );
        })
        .whereType<_DurationRecord>()
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    final totalConsultations = records.length;
    final totalMinutes = records.fold<int>(
      0,
      (sum, record) => sum + record.durationMinutes,
    );
    final totalHours = totalMinutes / 60;
    final workingDays = records
        .map((record) => DateFormat('yyyy-MM-dd').format(record.date))
        .toSet()
        .length;
    final consultationsPerDay =
        workingDays == 0 ? 0.0 : totalConsultations / workingDays;
    final averageDuration =
        totalConsultations == 0 ? 0.0 : totalMinutes / totalConsultations;

    final durationBuckets = [
      _DurationBucket('0-5 min', const Color(0xFFFF7F7F),
          records.where((record) => record.durationMinutes <= 5).length),
      _DurationBucket('5-10 min', const Color(0xFF5FD0CF),
          records.where((record) => record.durationMinutes > 5 && record.durationMinutes <= 10).length),
      _DurationBucket('10-15 min', const Color(0xFF68C6E5),
          records.where((record) => record.durationMinutes > 10 && record.durationMinutes <= 15).length),
      _DurationBucket('15-30 min', const Color(0xFFA8D9C2),
          records.where((record) => record.durationMinutes > 15 && record.durationMinutes <= 30).length),
      _DurationBucket('30+ min', const Color(0xFFFFC95C),
          records.where((record) => record.durationMinutes > 30).length),
    ];

    final now = DateTime.now();
    final lastSevenDays = List.generate(7, (index) {
      final date = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: 6 - index));
      final count = records.where((record) {
        return record.date.year == date.year &&
            record.date.month == date.month &&
            record.date.day == date.day;
      }).length;
      return _TrendPoint(DateFormat('E').format(date), count);
    });

    final completedCount =
        records.where((record) => record.appointment.isCompleted).length;
    final cancelledCount =
        records.where((record) => record.appointment.isCancelled).length;
    final incompleteCount = records
        .where((record) =>
            !record.appointment.isCompleted && !record.appointment.isCancelled)
        .length;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F8FA),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF5F8FA),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
        ),
        titleSpacing: 0,
        title: Text(
          'Average Call Duration',
          style: GoogleFonts.poppins(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Detailed Analytics & Insights',
                style: GoogleFonts.poppins(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 2.25,
                children: [
                  _InsightCard(
                    accent: const Color(0xFFB54AD6),
                    value: '$totalConsultations',
                    label: 'TOTAL CONSULTATIONS',
                  ),
                  _InsightCard(
                    accent: const Color(0xFFFFA31A),
                    value: '${totalHours.toStringAsFixed(1)}h',
                    label: 'TOTAL CONSULTATION HOURS',
                  ),
                  _InsightCard(
                    accent: const Color(0xFF56C271),
                    value: '$workingDays',
                    label: 'TOTAL WORKING DAYS',
                  ),
                  _InsightCard(
                    accent: const Color(0xFF2DA4F2),
                    value: consultationsPerDay.toStringAsFixed(1),
                    label: 'CONSULTATIONS PER DAY',
                  ),
                  _InsightCard(
                    accent: const Color(0xFFF34A7F),
                    value: '${averageDuration.toStringAsFixed(1)}m',
                    label: 'CALL DURATION PER CONSULTATION',
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _PanelCard(
                title: 'Call Duration Distribution',
                icon: Icons.access_time_filled_rounded,
                child: _DurationDistributionChart(
                  buckets: durationBuckets,
                ),
              ),
              const SizedBox(height: 16),
              _PanelCard(
                title: 'Last 7 Days Consultation Trend',
                icon: Icons.show_chart_rounded,
                child: _TrendChart(points: lastSevenDays),
              ),
              const SizedBox(height: 16),
              _PanelCard(
                title: 'Consultation Status Breakdown',
                icon: Icons.insert_chart_outlined_rounded,
                child: _StatusBreakdown(
                  completed: completedCount,
                  incomplete: incompleteCount,
                  cancelled: cancelledCount,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DurationRecord {
  const _DurationRecord({
    required this.appointment,
    required this.durationMinutes,
    required this.date,
  });

  final Appointment appointment;
  final int durationMinutes;
  final DateTime date;
}

class _DurationBucket {
  const _DurationBucket(this.label, this.color, this.count);

  final String label;
  final Color color;
  final int count;
}

class _TrendPoint {
  const _TrendPoint(this.label, this.value);

  final String label;
  final int value;
}

class _InsightCard extends StatelessWidget {
  const _InsightCard({
    required this.accent,
    required this.value,
    required this.label,
  });

  final Color accent;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            value,
            style: GoogleFonts.poppins(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: accent,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 9.2,
              fontWeight: FontWeight.w700,
              color: AppColors.textSecondary,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelCard extends StatelessWidget {
  const _PanelCard({
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
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.035),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: AppColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: GoogleFonts.poppins(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _DurationDistributionChart extends StatelessWidget {
  const _DurationDistributionChart({required this.buckets});

  final List<_DurationBucket> buckets;

  @override
  Widget build(BuildContext context) {
    final maxCount = buckets.fold<int>(0, (max, bucket) => math.max(max, bucket.count));
    return SizedBox(
      height: 210,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: buckets.map((bucket) {
          final heightFactor =
              maxCount == 0 ? 0.08 : (bucket.count / maxCount).clamp(0.08, 1.0);
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    '${bucket.count}',
                    style: GoogleFonts.inter(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: bucket.color,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    height: 120 * heightFactor,
                    width: 38,
                    decoration: BoxDecoration(
                      color: bucket.color,
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    bucket.label,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _TrendChart extends StatelessWidget {
  const _TrendChart({required this.points});

  final List<_TrendPoint> points;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 210,
      child: CustomPaint(
        painter: _TrendChartPainter(points: points),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 10, 18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: points
                .map(
                  (point) => Expanded(
                    child: Text(
                      point.label,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );
  }
}

class _TrendChartPainter extends CustomPainter {
  _TrendChartPainter({required this.points});

  final List<_TrendPoint> points;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 18.0;
    const right = 14.0;
    const top = 10.0;
    const bottom = 28.0;
    final chartWidth = size.width - left - right;
    final chartHeight = size.height - top - bottom;
    final maxValue =
        math.max(1, points.fold<int>(0, (max, point) => math.max(max, point.value)));

    final gridPaint = Paint()
      ..color = const Color(0xFFEAEFF3)
      ..strokeWidth = 1;
    for (var i = 0; i < 4; i++) {
      final y = top + (chartHeight / 3) * i;
      canvas.drawLine(Offset(left, y), Offset(size.width - right, y), gridPaint);
    }
    canvas.drawLine(
      Offset(left, top),
      Offset(left, size.height - bottom),
      gridPaint..color = const Color(0xFFD2DDE6),
    );

    final linePaint = Paint()
      ..color = AppColors.primary
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    final fillPaint = Paint()..color = Colors.white;

    final path = Path();
    final circleCenters = <Offset>[];
    for (var i = 0; i < points.length; i++) {
      final dx = left + (chartWidth / math.max(1, points.length - 1)) * i;
      final dy = top + chartHeight - (chartHeight * (points[i].value / maxValue));
      final point = Offset(dx, dy);
      circleCenters.add(point);
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    canvas.drawPath(path, linePaint);

    for (var i = 0; i < circleCenters.length; i++) {
      final center = circleCenters[i];
      canvas.drawCircle(center, 5.5, Paint()..color = AppColors.primary);
      canvas.drawCircle(center, 2.5, fillPaint);

      final textPainter = TextPainter(
        text: TextSpan(
          text: '${points[i].value}',
          style: GoogleFonts.inter(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            color: AppColors.primary,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      textPainter.paint(
        canvas,
        Offset(center.dx - textPainter.width / 2, center.dy - 16),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TrendChartPainter oldDelegate) {
    return oldDelegate.points != points;
  }
}

class _StatusBreakdown extends StatelessWidget {
  const _StatusBreakdown({
    required this.completed,
    required this.incomplete,
    required this.cancelled,
  });

  final int completed;
  final int incomplete;
  final int cancelled;

  @override
  Widget build(BuildContext context) {
    final total = math.max(1, completed + incomplete + cancelled);
    final items = [
      ('Completed', completed, const Color(0xFF69C36D)),
      ('Incomplete', incomplete, const Color(0xFF35A3F2)),
      ('Cancelled', cancelled, const Color(0xFFFFB11C)),
    ];

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: items.map((item) {
            final percent = ((item.$2 / total) * 100).round();
            return Column(
              children: [
                Container(
                  width: 74,
                  height: 74,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: item.$3,
                    border: Border.all(color: Colors.white, width: 4),
                    boxShadow: [
                      BoxShadow(
                        color: item.$3.withValues(alpha: 0.22),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      '${item.$2}',
                      style: GoogleFonts.poppins(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  item.$1,
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$percent%',
                  style: GoogleFonts.inter(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            );
          }).toList(),
        ),
        const SizedBox(height: 14),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 10,
          runSpacing: 8,
          children: items.map((item) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFF7F9FB),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: item.$3,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${item.$1}: ${item.$2}',
                    style: GoogleFonts.inter(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

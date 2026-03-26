import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../models/appointment_model.dart';
import '../services/api_service.dart';
import '../utils/constants.dart';
import 'appointment_detail_page.dart';
import 'login_page.dart';
import 'new_patient_page.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  List<Appointment> _myAppointments = [];
  List<Appointment> _allAppointments = [];
  bool _isLoading = true;
  String _userName = 'CHO';
  int _selectedTabIndex = 0;
  bool _sessionDialogShown = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this)
      ..addListener(() {
        if (!_tabController.indexIsChanging) {
          setState(() => _selectedTabIndex = _tabController.index);
        }
      });
    _loadData();

    // Also check after a short delay in case background session check
    // (from isLoggedIn) detected expiry before our API calls run
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && ApiService.sessionExpired) {
        _showSessionExpiredDialog();
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    // Reset session expired flag before fetching
    ApiService.sessionExpired = false;

    final userData = await ApiService.getUserData();
    if (userData != null) {
      _userName = userData['name'] ?? userData['cho_name'] ?? 'CHO';
    }

    final choId = await ApiService.getChoId();
    final results = await Future.wait([
      ApiService.getAppointmentsByChoId(choId),
      ApiService.getChoAppointments(),
    ]);

    if (!mounted) return;

    // Sort both lists: most recent appointment date first
    results[0].sort(_compareByDateDesc);
    results[1].sort(_compareByDateDesc);

    setState(() {
      _myAppointments = results[0];
      _allAppointments = results[1];
      _isLoading = false;
    });

    // If the API returned 401/403, prompt user to re-login
    if (ApiService.sessionExpired && mounted) {
      _showSessionExpiredDialog();
    }
  }

  void _showSessionExpiredDialog() {
    if (_sessionDialogShown) return;
    _sessionDialogShown = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                color: Color(0xFFFCE4EC),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.logout_rounded,
                color: Color(0xFFC62828),
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Session Logged Out',
                style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        content: Text(
          'Your session has expired. Please login again to continue.',
          style: GoogleFonts.inter(fontSize: 14, height: 1.5, color: AppColors.textSecondary),
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await ApiService.logout();
                if (!mounted) return;
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (_) => const LoginPage()),
                  (route) => false,
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(
                'Login Again',
                style: GoogleFonts.poppins(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Appointment> get _activeAppointments =>
      _selectedTabIndex == 0 ? _myAppointments : _allAppointments;

  int get _totalCount => _activeAppointments.length;
  int get _pendingCount => _activeAppointments.where((a) => a.isPending).length;
  int get _completedCount =>
      _activeAppointments.where((a) => a.isCompleted).length;
  int get _cancelledCount =>
      _activeAppointments.where((a) => a.isCancelled).length;

  Future<void> _handleLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          'Sign Out',
          style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        content: Text(
          'Are you sure you want to sign out?',
          style: GoogleFonts.inter(
            fontSize: 14,
            color: AppColors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Cancel',
              style: GoogleFonts.inter(color: AppColors.textSecondary),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
            ),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await ApiService.logout();
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const LoginPage()),
      );
    }
  }

  Future<void> _openNewPatient() async {
    final choId = await ApiService.getChoId();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NewPatientPage(choId: choId)),
    );
    _loadData();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F8FA),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openNewPatient,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: Text(
          'New Patient',
          style: GoogleFonts.inter(fontWeight: FontWeight.w600),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            _DashboardHeader(
              userName: _userName,
              greeting: _greeting(),
              totalCount: _totalCount,
              pendingCount: _pendingCount,
              completedCount: _completedCount,
              cancelledCount: _cancelledCount,
              onLogout: _handleLogout,
            ),
            _DashboardTabs(
              controller: _tabController,
              myCount: _myAppointments.length,
              allCount: _allAppointments.length,
            ),
            Expanded(
              child: _isLoading
                  ? const _DashboardLoading()
                  : TabBarView(
                      controller: _tabController,
                      children: [
                        _AppointmentList(
                          appointments: _myAppointments,
                          onRefresh: _loadData,
                        ),
                        _AppointmentList(
                          appointments: _allAppointments,
                          onRefresh: _loadData,
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good Morning';
    if (hour < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

  /// Sort appointments: most recent date at top
  int _compareByDateDesc(Appointment a, Appointment b) {
    final dateA = a.appointmentDate ?? a.createdAt ?? '';
    final dateB = b.appointmentDate ?? b.createdAt ?? '';
    try {
      return DateTime.parse(dateB).compareTo(DateTime.parse(dateA));
    } catch (_) {
      return dateB.compareTo(dateA);
    }
  }
}

class _DashboardHeader extends StatelessWidget {
  const _DashboardHeader({
    required this.userName,
    required this.greeting,
    required this.totalCount,
    required this.pendingCount,
    required this.completedCount,
    required this.cancelledCount,
    required this.onLogout,
  });

  final String userName;
  final String greeting;
  final int totalCount;
  final int pendingCount;
  final int completedCount;
  final int cancelledCount;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        gradient: AppColors.headerGradient,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.18),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      greeting,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.75),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      userName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Track appointments, review patient details, and stay on top of your day.',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        height: 1.5,
                        color: Colors.white.withValues(alpha: 0.78),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // ── Logout Button ──
              GestureDetector(
                onTap: onLogout,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.logout_rounded, color: Colors.white, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        'Logout',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _MetricCard(
                  label: 'Total',
                  value: totalCount,
                  icon: Icons.calendar_month_rounded,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MetricCard(
                  label: 'Pending',
                  value: pendingCount,
                  icon: Icons.pending_actions_rounded,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MetricCard(
                  label: 'Done',
                  value: completedCount,
                  icon: Icons.task_alt_rounded,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MetricCard(
                  label: 'Cancel',
                  value: cancelledCount,
                  icon: Icons.event_busy_rounded,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final int value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(icon, size: 18, color: Colors.white),
          const SizedBox(height: 8),
          Text(
            '$value',
            style: GoogleFonts.poppins(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 10,
              color: Colors.white.withValues(alpha: 0.78),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _DashboardTabs extends StatelessWidget {
  const _DashboardTabs({
    required this.controller,
    required this.myCount,
    required this.allCount,
  });

  final TabController controller;
  final int myCount;
  final int allCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: TabBar(
        controller: controller,
        dividerColor: Colors.transparent,
        isScrollable: false,
        labelPadding: EdgeInsets.zero,
        indicatorSize: TabBarIndicatorSize.tab,
        indicator: BoxDecoration(
          color: AppColors.primary,
          borderRadius: BorderRadius.circular(14),
        ),
        labelColor: Colors.white,
        unselectedLabelColor: AppColors.textPrimary,
        labelStyle: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700),
        unselectedLabelStyle:
            GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w500),
        tabs: [
          Tab(
            child: Center(
              child: Text(
                'My Appointments ($myCount)',
                textAlign: TextAlign.center,
              ),
            ),
          ),
          Tab(
            child: Center(
              child: Text(
                'All Appointments ($allCount)',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AppointmentList extends StatelessWidget {
  const _AppointmentList({
    required this.appointments,
    required this.onRefresh,
  });

  final List<Appointment> appointments;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    if (appointments.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRefresh,
        color: AppColors.primary,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.46,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.08),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.event_note_rounded,
                        size: 36,
                        color: AppColors.primary.withValues(alpha: 0.55),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'No appointments available',
                      style: GoogleFonts.poppins(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Pull to refresh or add a new patient.',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: AppColors.textSecondary,
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

    return RefreshIndicator(
      onRefresh: onRefresh,
      color: AppColors.primary,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
        itemCount: appointments.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final appointment = appointments[index];
          return _AppointmentTile(appointment: appointment);
        },
      ),
    );
  }
}

class _AppointmentTile extends StatelessWidget {
  const _AppointmentTile({required this.appointment});

  final Appointment appointment;

  @override
  Widget build(BuildContext context) {
    final statusColor = _statusColor(appointment.status);

    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AppointmentDetailPage(appointment: appointment),
          ),
        );
      },
      borderRadius: BorderRadius.circular(22),
      child: Ink(
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
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Center(
                      child: Text(
                        appointment.initials,
                        style: GoogleFonts.poppins(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primaryDeep,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          appointment.patientName ?? 'Unknown Patient',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.poppins(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _subtitleText(appointment),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            height: 1.45,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  _StatusChip(
                    label: appointment.status ?? 'Pending',
                    color: statusColor,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (appointment.appointmentDate != null)
                    _InfoPill(
                      icon: Icons.calendar_today_rounded,
                      text: _formatDate(appointment.appointmentDate!),
                    ),
                  if (appointment.appointmentTime != null)
                    _InfoPill(
                      icon: Icons.schedule_rounded,
                      text: appointment.appointmentTime!,
                    ),
                  if (appointment.tokenNumber != null)
                    _InfoPill(
                      icon: Icons.confirmation_number_outlined,
                      text: 'Token ${appointment.tokenNumber}',
                    ),
                  if (appointment.villageName != null)
                    _InfoPill(
                      icon: Icons.location_on_outlined,
                      text: appointment.villageName!,
                    ),
                ],
              ),
              if (_detailText(appointment).isNotEmpty) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FBFB),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    _detailText(appointment),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      height: 1.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    'View complete appointment',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    Icons.arrow_forward_rounded,
                    size: 18,
                    color: AppColors.primary,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _subtitleText(Appointment appointment) {
    final parts = <String>[
      if (appointment.patientPhone?.isNotEmpty == true) appointment.patientPhone!,
      if (appointment.age != null) '${appointment.age} yrs',
      if (appointment.gender?.isNotEmpty == true) appointment.gender!,
    ];
    return parts.isEmpty ? 'Patient record available' : parts.join('  •  ');
  }

  static String _detailText(Appointment appointment) {
    final details = <String>[
      if (appointment.reason?.trim().isNotEmpty == true) appointment.reason!.trim(),
      if (appointment.notes?.trim().isNotEmpty == true) appointment.notes!.trim(),
    ];
    return details.join(' • ');
  }

  static String _formatDate(String rawDate) {
    try {
      return DateFormat('dd MMM yyyy').format(DateTime.parse(rawDate));
    } catch (_) {
      return rawDate;
    }
  }

  static Color _statusColor(String? status) {
    final normalized = (status ?? 'pending').toLowerCase();
    if (normalized == 'completed' || normalized == 'done') {
      return const Color(0xFF2E7D32);
    }
    if (normalized == 'cancelled' || normalized == 'canceled') {
      return const Color(0xFFC62828);
    }
    return const Color(0xFFB26A00);
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Text(
        label.toUpperCase(),
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF7FAFB),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppColors.primary),
          const SizedBox(width: 6),
          Text(
            text,
            style: GoogleFonts.inter(
              fontSize: 12,
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _DashboardLoading extends StatelessWidget {
  const _DashboardLoading();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(
            color: AppColors.primary,
            strokeWidth: 2.6,
          ),
          const SizedBox(height: 16),
          Text(
            'Loading dashboard data...',
            style: GoogleFonts.inter(
              fontSize: 13,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

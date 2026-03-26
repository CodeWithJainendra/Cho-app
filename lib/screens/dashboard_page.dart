import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../models/appointment_model.dart';
import '../services/api_service.dart';
import '../services/session_expiry_service.dart';
import '../utils/constants.dart';
import 'appointment_detail_page.dart';
import 'login_page.dart';
import 'new_patient_page.dart';
import 'telemedicine_page.dart';

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
  bool _isSearchActionExpanded = false;

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

    if (ApiService.sessionExpired && mounted) {
      SessionExpiryService.notifySessionExpired();
    }
  }

  List<Appointment> get _activeAppointments =>
      _selectedTabIndex == 0 ? _myAppointments : _allAppointments;

  int get _totalCount => _activeAppointments.length;
  int get _pendingCount => _activeAppointments.where((a) => a.isPending).length;
  int get _completedCount =>
      _activeAppointments.where((a) => a.isCompleted).length;
  int get _cancelledCount =>
      _activeAppointments.where((a) => a.isCancelled).length;

  List<Appointment> get _searchableAppointments {
    if (_allAppointments.isNotEmpty) return _allAppointments;
    return _myAppointments;
  }

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

  Future<void> _openBookAppointmentPage() async {
    final choId = await ApiService.getChoId();
    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NewPatientPage(
          choId: choId,
          initialTab: 0,
        ),
      ),
    );

    _loadData();
  }

  Future<void> _openDoctorsPage() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const TelemedicinePage(),
      ),
    );
  }

  Future<void> _openAppointmentSearchPage() async {
    if (_isSearchActionExpanded) return;

    setState(() => _isSearchActionExpanded = true);
    await Future.delayed(const Duration(milliseconds: 220));
    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _AppointmentSearchPage(
          appointments: _searchableAppointments,
        ),
      ),
    );

    if (!mounted) return;
    setState(() => _isSearchActionExpanded = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F8FA),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openBookAppointmentPage,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: Text(
          'New Patient',
          style: GoogleFonts.inter(fontWeight: FontWeight.w600),
        ),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isCompact = constraints.maxHeight < 560;

            return Column(
              children: [
                _DashboardHeader(
                  userName: _userName,
                  greeting: _greeting(),
                  totalCount: _totalCount,
                  pendingCount: _pendingCount,
                  completedCount: _completedCount,
                  cancelledCount: _cancelledCount,
                  isCompact: isCompact,
                  onLogout: _handleLogout,
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, isCompact ? 8 : 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: _QuickAccessCard(
                          title: 'Book Appointment',
                          icon: Icons.add_task_rounded,
                          onTap: _openBookAppointmentPage,
                          isCompact: isCompact,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _QuickAccessCard(
                          title: 'Show Doctors',
                          icon: Icons.medical_services_outlined,
                          onTap: _openDoctorsPage,
                          isCompact: isCompact,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, isCompact ? 6 : 10),
                  child: _AppointmentsSectionHeader(
                    title: 'Appointments',
                    isCompact: isCompact,
                    isSearchExpanded: _isSearchActionExpanded,
                    onSearchTap: _openAppointmentSearchPage,
                  ),
                ),
                _DashboardTabs(
                  controller: _tabController,
                  myCount: _myAppointments.length,
                  allCount: _allAppointments.length,
                  isCompact: isCompact,
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
            );
          },
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
    required this.isCompact,
    required this.onLogout,
  });

  final String userName;
  final String greeting;
  final int totalCount;
  final int pendingCount;
  final int completedCount;
  final int cancelledCount;
  final bool isCompact;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin:
          EdgeInsets.fromLTRB(16, isCompact ? 8 : 12, 16, isCompact ? 8 : 12),
      padding: EdgeInsets.fromLTRB(
        isCompact ? 14 : 18,
        isCompact ? 12 : 16,
        isCompact ? 14 : 18,
        isCompact ? 12 : 16,
      ),
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
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      greeting,
                      style: GoogleFonts.inter(
                        fontSize: isCompact ? 11 : 12,
                        color: Colors.white.withValues(alpha: 0.75),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      userName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(
                        fontSize: isCompact ? 20 : 24,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              InkWell(
                onTap: onLogout,
                borderRadius: BorderRadius.circular(16),
                child: Ink(
                  padding: EdgeInsets.all(isCompact ? 9 : 11),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(16),
                    border:
                        Border.all(color: Colors.white.withValues(alpha: 0.15)),
                  ),
                  child: const Icon(
                    Icons.logout_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: isCompact ? 10 : 14),
          Row(
            children: [
              Expanded(
                child: _MetricCard(
                  label: 'Total',
                  value: totalCount,
                  icon: Icons.calendar_month_rounded,
                  isCompact: isCompact,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MetricCard(
                  label: 'Pending',
                  value: pendingCount,
                  icon: Icons.pending_actions_rounded,
                  isCompact: isCompact,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MetricCard(
                  label: 'Done',
                  value: completedCount,
                  icon: Icons.task_alt_rounded,
                  isCompact: isCompact,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MetricCard(
                  label: 'Cancel',
                  value: cancelledCount,
                  icon: Icons.event_busy_rounded,
                  isCompact: isCompact,
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
    required this.isCompact,
  });

  final String label;
  final int value;
  final IconData icon;
  final bool isCompact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        vertical: isCompact ? 8 : 12,
        horizontal: isCompact ? 6 : 8,
      ),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          if (!isCompact) ...[
            Icon(icon, size: 18, color: Colors.white),
            const SizedBox(height: 8),
          ],
          Text(
            '$value',
            style: GoogleFonts.poppins(
              fontSize: isCompact ? 16 : 18,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          SizedBox(height: isCompact ? 1 : 2),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: isCompact ? 9 : 10,
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
    required this.isCompact,
  });

  final TabController controller;
  final int myCount;
  final int allCount;
  final bool isCompact;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.fromLTRB(16, 0, 16, isCompact ? 8 : 12),
      padding: EdgeInsets.all(isCompact ? 4 : 6),
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
        labelStyle: GoogleFonts.inter(
            fontSize: isCompact ? 11 : 12, fontWeight: FontWeight.w700),
        unselectedLabelStyle: GoogleFonts.inter(
            fontSize: isCompact ? 11 : 12, fontWeight: FontWeight.w600),
        tabs: [
          Tab(
            child: _DashboardTabLabel(
              label: 'My Appointments',
              count: myCount,
              isCompact: isCompact,
            ),
          ),
          Tab(
            child: _DashboardTabLabel(
              label: 'All Appointments',
              count: allCount,
              isCompact: isCompact,
            ),
          ),
        ],
      ),
    );
  }
}

class _DashboardTabLabel extends StatelessWidget {
  const _DashboardTabLabel({
    required this.label,
    required this.count,
    required this.isCompact,
  });

  final String label;
  final int count;
  final bool isCompact;

  @override
  Widget build(BuildContext context) {
    final parentTabBar = DefaultTextStyle.of(context).style.color;
    final textColor = parentTabBar ?? Colors.white;

    return Center(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          const SizedBox(width: 6),
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: isCompact ? 7 : 8,
              vertical: isCompact ? 1.5 : 2,
            ),
            decoration: BoxDecoration(
              color: Colors.white
                  .withValues(alpha: textColor == Colors.white ? 0.18 : 0.85),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '$count',
              style: GoogleFonts.inter(
                fontSize: isCompact ? 9 : 10,
                fontWeight: FontWeight.w700,
                color: textColor == Colors.white
                    ? Colors.white
                    : AppColors.primaryDeep,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickAccessCard extends StatelessWidget {
  const _QuickAccessCard({
    required this.title,
    required this.icon,
    required this.onTap,
    required this.isCompact,
  });

  final String title;
  final IconData icon;
  final VoidCallback onTap;
  final bool isCompact;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          padding: EdgeInsets.symmetric(
            horizontal: isCompact ? 12 : 13,
            vertical: isCompact ? 10 : 11,
          ),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.18),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.05),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: isCompact ? 34 : 38,
                height: isCompact ? 34 : 38,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  size: isCompact ? 17 : 18,
                  color: AppColors.primaryDeep,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.dmSans(
                    fontSize: isCompact ? 11 : 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                    letterSpacing: 0.1,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: isCompact ? 14 : 15,
                color: AppColors.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppointmentsSectionHeader extends StatelessWidget {
  const _AppointmentsSectionHeader({
    required this.title,
    required this.isCompact,
    required this.isSearchExpanded,
    required this.onSearchTap,
  });

  final String title;
  final bool isCompact;
  final bool isSearchExpanded;
  final VoidCallback onSearchTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.poppins(
                  fontSize: isCompact ? 16 : 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        GestureDetector(
          onTap: onSearchTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            width: isSearchExpanded ? 112 : 40,
            height: isCompact ? 36 : 38,
            padding:
                EdgeInsets.symmetric(horizontal: isSearchExpanded ? 12 : 0),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: AppColors.cardBorder),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.search_rounded,
                  size: 18,
                  color: AppColors.textPrimary,
                ),
                if (isSearchExpanded) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Search',
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
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
        separatorBuilder: (_, __) => const SizedBox(height: 10),
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
      borderRadius: BorderRadius.circular(18),
      child: Ink(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.cardBorder),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.035),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(13, 13, 13, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Center(
                      child: Text(
                        appointment.initials,
                        style: GoogleFonts.poppins(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primaryDeep,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          appointment.patientName ?? 'Unknown Patient',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.poppins(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _subtitleText(appointment),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            height: 1.35,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _StatusChip(
                    label: appointment.status ?? 'Pending',
                    color: statusColor,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
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
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FBFB),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _detailText(appointment),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      height: 1.4,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FCFC),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.12),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Icon(
                        Icons.description_outlined,
                        size: 12,
                        color: AppColors.primaryDeep,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        'Appointment details',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.dmSans(
                          fontSize: 10.8,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Open',
                            style: GoogleFonts.inter(
                              fontSize: 9.8,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 3),
                          const Icon(
                            Icons.arrow_forward_rounded,
                            size: 11,
                            color: Colors.white,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _subtitleText(Appointment appointment) {
    final parts = <String>[
      if (appointment.patientPhone?.isNotEmpty == true)
        appointment.patientPhone!,
      if (appointment.age != null) '${appointment.age} yrs',
      if (appointment.gender?.isNotEmpty == true) appointment.gender!,
    ];
    return parts.isEmpty ? 'Patient record available' : parts.join('  •  ');
  }

  static String _detailText(Appointment appointment) {
    final details = <String>[
      if (appointment.reason?.trim().isNotEmpty == true)
        appointment.reason!.trim(),
      if (appointment.notes?.trim().isNotEmpty == true)
        appointment.notes!.trim(),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Text(
        label.toUpperCase(),
        style: GoogleFonts.inter(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 0.2,
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF7FAFB),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: AppColors.primary),
          const SizedBox(width: 5),
          Text(
            text,
            style: GoogleFonts.inter(
              fontSize: 10.5,
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxHeight < 96;

        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: isCompact ? 24 : 32,
                height: isCompact ? 24 : 32,
                child: const CircularProgressIndicator(
                  color: AppColors.primary,
                  strokeWidth: 2.6,
                ),
              ),
              if (!isCompact) ...[
                const SizedBox(height: 16),
                Text(
                  'Loading dashboard data...',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _AppointmentSearchPage extends StatefulWidget {
  const _AppointmentSearchPage({
    required this.appointments,
  });

  final List<Appointment> appointments;

  @override
  State<_AppointmentSearchPage> createState() => _AppointmentSearchPageState();
}

class _AppointmentSearchPageState extends State<_AppointmentSearchPage> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Appointment> get _filteredAppointments {
    if (_query.isEmpty) return widget.appointments;

    return widget.appointments.where((appointment) {
      final haystack = [
        appointment.patientName,
        appointment.patientPhone,
        appointment.abhaId,
        appointment.villageName,
        appointment.tokenNumber?.toString(),
        appointment.reason,
        appointment.notes,
      ].whereType<String>().join(' ').toLowerCase();

      return haystack.contains(_query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F8FA),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    constraints:
                        const BoxConstraints(minWidth: 34, minHeight: 34),
                    padding: const EdgeInsets.all(6),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: AppColors.textPrimary,
                      side: const BorderSide(color: AppColors.cardBorder),
                    ),
                    icon:
                        const Icon(Icons.arrow_back_ios_new_rounded, size: 16),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Container(
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppColors.cardBorder),
                      ),
                      child: TextField(
                        controller: _searchController,
                        autofocus: true,
                        decoration: InputDecoration(
                          hintText: 'Search patient',
                          hintStyle: GoogleFonts.inter(
                            fontSize: 12,
                            color: AppColors.textHint,
                          ),
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            size: 18,
                            color: AppColors.textSecondary,
                          ),
                          suffixIcon: _query.isEmpty
                              ? null
                              : IconButton(
                                  onPressed: () => _searchController.clear(),
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                        ),
                        style: GoogleFonts.inter(
                          fontSize: 12.5,
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _filteredAppointments.isEmpty
                  ? Center(
                      child: Text(
                        'No patients found',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      itemCount: _filteredAppointments.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        return _AppointmentTile(
                          appointment: _filteredAppointments[index],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

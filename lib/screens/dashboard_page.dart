import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../models/appointment_model.dart';
import '../services/api_service.dart';
import '../services/session_expiry_service.dart';
import '../utils/constants.dart';
import 'average_call_duration_page.dart';
import 'appointment_detail_page.dart';
import 'login_page.dart';
import 'new_patient_page.dart';
import 'telemedicine_page.dart';

enum _DashboardMetricFilter {
  todaysConsultations,
  monthlyConsultations,
  todaysFollowUps,
  averageCallDuration,
}

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
  _DashboardMetricFilter _selectedMetricFilter =
      _DashboardMetricFilter.todaysConsultations;

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

  List<Appointment> get _choAppointments {
    if (_myAppointments.isNotEmpty) return _myAppointments;
    return _activeAppointments;
  }

  int get _todayConsultationsCount {
    final today = DateTime.now();
    return _choAppointments.where((appointment) {
      final date = _appointmentDateOrCreatedAt(appointment);
      return date != null && _isSameDate(date, today);
    }).length;
  }

  int get _monthlyConsultationsCount {
    final now = DateTime.now();
    return _choAppointments.where((appointment) {
      final date = _appointmentDateOrCreatedAt(appointment);
      return date != null && date.year == now.year && date.month == now.month;
    }).length;
  }

  int get _todayFollowUpsCount {
    final today = DateTime.now();
    return _choAppointments.where((appointment) {
      final date = _appointmentDateOrCreatedAt(appointment);
      if (date == null || !_isSameDate(date, today)) return false;

      final appointmentType = (appointment.appointmentType ?? '').toLowerCase();
      final reason = (appointment.reason ?? '').toLowerCase();
      final notes = (appointment.notes ?? '').toLowerCase();
      final haystack = '$appointmentType $reason $notes';
      return haystack.contains('follow');
    }).length;
  }

  String get _averageCallDurationLabel {
    final durations = _choAppointments
        .map(_extractDurationMinutes)
        .whereType<int>()
        .where((duration) => duration > 0)
        .toList();

    if (durations.isEmpty) return '0m';

    final average =
        durations.reduce((sum, duration) => sum + duration) / durations.length;
    final rounded = average.round();
    return '${rounded}m';
  }

  List<Appointment> _applyMetricFilter(List<Appointment> appointments) {
    switch (_selectedMetricFilter) {
      case _DashboardMetricFilter.todaysConsultations:
        final today = DateTime.now();
        return appointments.where((appointment) {
          final date = _appointmentDateOrCreatedAt(appointment);
          return date != null && _isSameDate(date, today);
        }).toList();
      case _DashboardMetricFilter.monthlyConsultations:
        final now = DateTime.now();
        return appointments.where((appointment) {
          final date = _appointmentDateOrCreatedAt(appointment);
          return date != null && date.year == now.year && date.month == now.month;
        }).toList();
      case _DashboardMetricFilter.todaysFollowUps:
        final today = DateTime.now();
        return appointments.where((appointment) {
          final date = _appointmentDateOrCreatedAt(appointment);
          if (date == null || !_isSameDate(date, today)) return false;

          final appointmentType = (appointment.appointmentType ?? '').toLowerCase();
          final reason = (appointment.reason ?? '').toLowerCase();
          final notes = (appointment.notes ?? '').toLowerCase();
          final haystack = '$appointmentType $reason $notes';
          return haystack.contains('follow');
        }).toList();
      case _DashboardMetricFilter.averageCallDuration:
        return appointments
            .where((appointment) => (_extractDurationMinutes(appointment) ?? 0) > 0)
            .toList();
    }
  }

  List<Appointment> get _filteredMyAppointments => _applyMetricFilter(_myAppointments);

  List<Appointment> get _searchableAppointments {
    if (_allAppointments.isNotEmpty) return _allAppointments;
    return _myAppointments;
  }

  DateTime? _appointmentDateOrCreatedAt(Appointment appointment) {
    final rawDate = appointment.appointmentDate ?? appointment.createdAt;
    if (rawDate == null || rawDate.isEmpty) return null;
    try {
      return DateTime.parse(rawDate);
    } catch (_) {
      return null;
    }
  }

  bool _isSameDate(DateTime first, DateTime second) {
    return first.year == second.year &&
        first.month == second.month &&
        first.day == second.day;
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

  Future<void> _openAverageCallDurationPage() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AverageCallDurationPage(
          appointments: _choAppointments,
          userName: _userName,
        ),
      ),
    );
  }

  void _handleMetricSelection(_DashboardMetricFilter filter) {
    if (filter == _DashboardMetricFilter.averageCallDuration) {
      _openAverageCallDurationPage();
      return;
    }

    setState(() => _selectedMetricFilter = filter);
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
                  todaysConsultations: _todayConsultationsCount,
                  monthlyConsultations: _monthlyConsultationsCount,
                  todaysFollowUps: _todayFollowUpsCount,
                  averageCallDuration: _averageCallDurationLabel,
                  selectedFilter: _selectedMetricFilter,
                  onMetricSelected: _handleMetricSelection,
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
                  myCount: _filteredMyAppointments.length,
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
                              appointments: _filteredMyAppointments,
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
    required this.todaysConsultations,
    required this.monthlyConsultations,
    required this.todaysFollowUps,
    required this.averageCallDuration,
    required this.selectedFilter,
    required this.onMetricSelected,
    required this.isCompact,
    required this.onLogout,
  });

  final String userName;
  final String greeting;
  final int todaysConsultations;
  final int monthlyConsultations;
  final int todaysFollowUps;
  final String averageCallDuration;
  final _DashboardMetricFilter selectedFilter;
  final ValueChanged<_DashboardMetricFilter> onMetricSelected;
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
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onLogout,
                  customBorder: const CircleBorder(),
                  child: Ink(
                    width: isCompact ? 40 : 44,
                    height: isCompact ? 40 : 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.2),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.22),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.logout_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: isCompact ? 10 : 14),
          Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _MetricCard(
                      filter: _DashboardMetricFilter.todaysConsultations,
                      label: "Today's Consultations",
                      value: '$todaysConsultations',
                      icon: Icons.insights_rounded,
                      isSelected:
                          selectedFilter == _DashboardMetricFilter.todaysConsultations,
                      onTap: onMetricSelected,
                      isCompact: isCompact,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MetricCard(
                      filter: _DashboardMetricFilter.monthlyConsultations,
                      label: 'Monthly Consultations',
                      value: '$monthlyConsultations',
                      icon: Icons.medical_services_rounded,
                      isSelected:
                          selectedFilter == _DashboardMetricFilter.monthlyConsultations,
                      onTap: onMetricSelected,
                      isCompact: isCompact,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _MetricCard(
                      filter: _DashboardMetricFilter.todaysFollowUps,
                      label: "Today's Follow-ups",
                      value: '$todaysFollowUps',
                      icon: Icons.event_available_rounded,
                      isSelected:
                          selectedFilter == _DashboardMetricFilter.todaysFollowUps,
                      onTap: onMetricSelected,
                      isCompact: isCompact,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MetricCard(
                      filter: _DashboardMetricFilter.averageCallDuration,
                      label: 'Average Call Duration',
                      value: averageCallDuration,
                      icon: Icons.schedule_rounded,
                      isSelected:
                          selectedFilter == _DashboardMetricFilter.averageCallDuration,
                      onTap: onMetricSelected,
                      isCompact: isCompact,
                    ),
                  ),
                ],
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
    required this.filter,
    required this.label,
    required this.value,
    required this.icon,
    required this.isSelected,
    required this.onTap,
    required this.isCompact,
  });

  final _DashboardMetricFilter filter;
  final String label;
  final String value;
  final IconData icon;
  final bool isSelected;
  final ValueChanged<_DashboardMetricFilter> onTap;
  final bool isCompact;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: isCompact ? 68 : 74,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => onTap(filter),
          borderRadius: BorderRadius.circular(14),
          child: Ink(
            padding: EdgeInsets.symmetric(
              vertical: isCompact ? 6 : 7,
              horizontal: isCompact ? 5 : 6,
            ),
            decoration: BoxDecoration(
              color: isSelected
                  ? Colors.white.withValues(alpha: 0.24)
                  : Colors.white.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(14),
              border: isSelected
                  ? Border.all(color: Colors.white.withValues(alpha: 0.45))
                  : null,
            ),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (!isCompact) ...[
                    Icon(
                      icon,
                      size: 14,
                      color: isSelected
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.92),
                    ),
                    const SizedBox(height: 4),
                  ],
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        value,
                        style: GoogleFonts.poppins(
                          fontSize: isCompact ? 13 : 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: isCompact ? 1 : 2),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: isCompact ? 7.8 : 8.4,
                        color: Colors.white.withValues(
                          alpha: isSelected ? 0.92 : 0.78,
                        ),
                        fontWeight: FontWeight.w600,
                        height: 1.08,
                      ),
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
  DateTime? _startDate;
  DateTime? _endDate;
  String? _selectedStatus;
  int? _minDuration;
  int? _maxDuration;

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

      final matchesQuery = _query.isEmpty || haystack.contains(_query);
      final matchesDate = _matchesDateRange(appointment);
      final matchesStatus = _matchesStatus(appointment);
      final matchesDuration = _matchesDuration(appointment);

      return matchesQuery && matchesDate && matchesStatus && matchesDuration;
    }).toList();
  }

  bool get _hasActiveFilters =>
      _startDate != null ||
      _endDate != null ||
      _selectedStatus != null ||
      _minDuration != null ||
      _maxDuration != null;

  bool _matchesDateRange(Appointment appointment) {
    if (_startDate == null && _endDate == null) return true;

    final appointmentDate = _parseAppointmentDate(appointment);
    if (appointmentDate == null) return false;

    final dateOnly = DateTime(
      appointmentDate.year,
      appointmentDate.month,
      appointmentDate.day,
    );

    if (_startDate != null) {
      final start = DateTime(_startDate!.year, _startDate!.month, _startDate!.day);
      if (dateOnly.isBefore(start)) return false;
    }

    if (_endDate != null) {
      final end = DateTime(_endDate!.year, _endDate!.month, _endDate!.day);
      if (dateOnly.isAfter(end)) return false;
    }

    return true;
  }

  bool _matchesStatus(Appointment appointment) {
    if (_selectedStatus == null) return true;

    final normalizedStatus = (appointment.status ?? '').trim().toLowerCase();

    switch (_selectedStatus) {
      case 'completed':
        return appointment.isCompleted;
      case 'incomplete':
        return !appointment.isCompleted &&
            !appointment.isCancelled &&
            normalizedStatus != 'cancelled' &&
            normalizedStatus != 'canceled';
      case 'cancelled':
        return appointment.isCancelled;
      default:
        return true;
    }
  }

  bool _matchesDuration(Appointment appointment) {
    if (_minDuration == null && _maxDuration == null) return true;

    final duration = _extractDurationMinutes(appointment);
    if (duration == null) return false;
    if (_minDuration != null && duration < _minDuration!) return false;
    if (_maxDuration != null && duration > _maxDuration!) return false;
    return true;
  }

  DateTime? _parseAppointmentDate(Appointment appointment) {
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

  String _formatInputDate(DateTime? date) {
    if (date == null) return 'dd / mm / yyyy';
    return DateFormat('dd / MM / yyyy').format(date);
  }

  Future<void> _openFilterSheet() async {
    DateTime? tempStartDate = _startDate;
    DateTime? tempEndDate = _endDate;
    String? tempStatus = _selectedStatus;
    String tempMinDuration = _minDuration?.toString() ?? '';
    String tempMaxDuration = _maxDuration?.toString() ?? '';

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Future<void> pickDate({
              required bool isStart,
            }) async {
              final initialDate =
                  (isStart ? tempStartDate : tempEndDate) ?? DateTime.now();
              final picked = await showDatePicker(
                context: sheetContext,
                initialDate: initialDate,
                firstDate: DateTime(2020),
                lastDate: DateTime(2100),
              );
              if (picked == null) return;

              setSheetState(() {
                if (isStart) {
                  tempStartDate = picked;
                  if (tempEndDate != null && tempEndDate!.isBefore(picked)) {
                    tempEndDate = picked;
                  }
                } else {
                  tempEndDate = picked;
                  if (tempStartDate != null &&
                      tempStartDate!.isAfter(picked)) {
                    tempStartDate = picked;
                  }
                }
              });
            }

            Widget dateField({
              required DateTime? value,
              required VoidCallback onTap,
            }) {
              final hasValue = value != null;
              return Expanded(
                child: InkWell(
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    height: 50,
                    padding: const EdgeInsets.symmetric(horizontal: 13),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFD9DEE3)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _formatInputDate(value),
                            style: GoogleFonts.inter(
                              fontSize: 12.2,
                              fontWeight: hasValue ? FontWeight.w600 : FontWeight.w500,
                              color: hasValue
                                  ? AppColors.textPrimary
                                  : AppColors.textHint,
                            ),
                          ),
                        ),
                        const Icon(
                          Icons.calendar_today_outlined,
                          size: 16,
                          color: AppColors.textSecondary,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }

            Widget durationField({
              required String initialValue,
              required String hintText,
              required ValueChanged<String> onChanged,
            }) {
              return Expanded(
                child: Container(
                  height: 50,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFD9DEE3)),
                  ),
                  child: TextFormField(
                    key: ValueKey('$hintText-$initialValue'),
                    initialValue: initialValue,
                    onChanged: onChanged,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      hintText: hintText,
                      hintStyle: GoogleFonts.inter(
                        fontSize: 12.2,
                        color: AppColors.textHint,
                      ),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 13,
                        vertical: 14,
                      ),
                    ),
                    style: GoogleFonts.inter(
                      fontSize: 12.2,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              );
            }

            return SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  16,
                  16,
                  MediaQuery.of(sheetContext).viewInsets.bottom + 10,
                ),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFDFEFE),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: AppColors.primary, width: 1.6),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Date Range',
                        style: GoogleFonts.poppins(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          dateField(
                            value: tempStartDate,
                            onTap: () => pickDate(isStart: true),
                          ),
                          const SizedBox(width: 10),
                          dateField(
                            value: tempEndDate,
                            onTap: () => pickDate(isStart: false),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'Status',
                        style: GoogleFonts.poppins(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ('completed', 'completed'),
                          ('incomplete', 'incomplete'),
                          ('cancelled', 'cancelled'),
                        ].map((entry) {
                          final isSelected = tempStatus == entry.$1;
                          return ChoiceChip(
                            label: Text(
                              entry.$2,
                              style: GoogleFonts.inter(
                                fontSize: 11.6,
                                fontWeight: FontWeight.w600,
                                color: isSelected
                                    ? Colors.white
                                    : AppColors.textPrimary,
                              ),
                            ),
                            selected: isSelected,
                            onSelected: (_) {
                              setSheetState(() {
                                tempStatus =
                                    isSelected ? null : entry.$1;
                              });
                            },
                            showCheckmark: false,
                            backgroundColor: Colors.white,
                            selectedColor: AppColors.primary,
                            side: BorderSide(
                              color: isSelected
                                  ? AppColors.primary
                                  : const Color(0xFFD9DEE3),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(999),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'Call Duration (minutes)',
                        style: GoogleFonts.poppins(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          durationField(
                            initialValue: tempMinDuration,
                            hintText: '0',
                            onChanged: (value) => tempMinDuration = value,
                          ),
                          const SizedBox(width: 10),
                          durationField(
                            initialValue: tempMaxDuration,
                            hintText: 'Max',
                            onChanged: (value) => tempMaxDuration = value,
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Divider(
                        height: 1,
                        color: Colors.grey.shade200,
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () {
                                setSheetState(() {
                                  tempStartDate = null;
                                  tempEndDate = null;
                                  tempStatus = null;
                                  tempMinDuration = '';
                                  tempMaxDuration = '';
                                });
                              },
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(44),
                                side: const BorderSide(
                                  color: Color(0xFFD9DEE3),
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: Text(
                                'Clear All',
                                style: GoogleFonts.inter(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () {
                                setState(() {
                                  _startDate = tempStartDate;
                                  _endDate = tempEndDate;
                                  _selectedStatus = tempStatus;
                                  _minDuration = int.tryParse(
                                    tempMinDuration.trim(),
                                  );
                                  _maxDuration = int.tryParse(
                                    tempMaxDuration.trim(),
                                  );
                                });
                                Navigator.pop(sheetContext);
                              },
                              style: ElevatedButton.styleFrom(
                                minimumSize: const Size.fromHeight(44),
                                backgroundColor: AppColors.primary,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: Text(
                                'Apply Filters',
                                style: GoogleFonts.inter(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
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
                  const SizedBox(width: 10),
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      IconButton(
                        onPressed: _openFilterSheet,
                        constraints:
                            const BoxConstraints(minWidth: 44, minHeight: 44),
                        padding: const EdgeInsets.all(10),
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: AppColors.textPrimary,
                          side: BorderSide(
                            color: _hasActiveFilters
                                ? AppColors.primary
                                : AppColors.cardBorder,
                          ),
                        ),
                        icon: Icon(
                          Icons.tune_rounded,
                          size: 20,
                          color: _hasActiveFilters
                              ? AppColors.primary
                              : AppColors.textPrimary,
                        ),
                      ),
                      if (_hasActiveFilters)
                        Positioned(
                          top: -2,
                          right: -1,
                          child: Container(
                            width: 10,
                            height: 10,
                            decoration: const BoxDecoration(
                              color: AppColors.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            if (_hasActiveFilters)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      if (_startDate != null || _endDate != null)
                        _SearchFilterTag(
                          label:
                              '${_formatInputDate(_startDate)} - ${_formatInputDate(_endDate)}',
                        ),
                      if (_selectedStatus != null)
                        _SearchFilterTag(
                          label:
                              'Status: ${_selectedStatus![0].toUpperCase()}${_selectedStatus!.substring(1)}',
                        ),
                      if (_minDuration != null || _maxDuration != null)
                        _SearchFilterTag(
                          label:
                              'Duration: ${_minDuration ?? 0}-${_maxDuration ?? 'Max'} min',
                        ),
                    ],
                  ),
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

class _SearchFilterTag extends StatelessWidget {
  const _SearchFilterTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: AppColors.primaryDeep,
        ),
      ),
    );
  }
}

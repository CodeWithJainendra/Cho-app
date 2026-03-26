import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/booking_service.dart';
import '../utils/constants.dart';
import 'create_abha_page.dart';
import 'telemedicine_page.dart';

class NewPatientPage extends StatefulWidget {
  final int choId;

  const NewPatientPage({super.key, required this.choId});

  @override
  State<NewPatientPage> createState() => _NewPatientPageState();
}

class _NewPatientPageState extends State<NewPatientPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  final _mobileController = TextEditingController();
  final _abhaController = TextEditingController();
  final _otpController = TextEditingController();

  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _ageController = TextEditingController();
  final _abhaManualController = TextEditingController();
  final _villageController = TextEditingController();
  final _blockController = TextEditingController();
  final _districtController = TextEditingController();
  final _stateController = TextEditingController();
  final _pincodeController = TextEditingController();

  final _spo2Controller = TextEditingController();
  final _temperatureController = TextEditingController();
  final _bpSysController = TextEditingController();
  final _bpDiaController = TextEditingController();
  final _heightController = TextEditingController();
  final _weightController = TextEditingController();
  final _complaintsController = TextEditingController();

  String? _gender;
  bool _isBusy = false;
  bool _showOtpDialog = false;
  bool _showAccountDialog = false;
  _PatientPreview? _patientPreview;
  _OtpFlow? _otpFlow;
  String? _abdmAccessToken;
  String? _abdmPublicKey;
  String? _otpTxnId;
  String? _mobileSearchTxnId;
  List<_MobileAbhaAccount> _mobileAccounts = const [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this)
      ..addListener(() {
        if (!_tabController.indexIsChanging) {
          setState(() => _patientPreview = null);
        }
      });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _mobileController.dispose();
    _abhaController.dispose();
    _otpController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _ageController.dispose();
    _abhaManualController.dispose();
    _villageController.dispose();
    _blockController.dispose();
    _districtController.dispose();
    _stateController.dispose();
    _pincodeController.dispose();
    _spo2Controller.dispose();
    _temperatureController.dispose();
    _bpSysController.dispose();
    _bpDiaController.dispose();
    _heightController.dispose();
    _weightController.dispose();
    _complaintsController.dispose();
    super.dispose();
  }

  Future<void> _verifyMobile() async {
    final mobile = _mobileController.text.trim();
    if (!RegExp(r'^\d{10}$').hasMatch(mobile)) {
      _showSnack('Enter a valid 10-digit mobile number.');
      return;
    }

    _clearTransientUi();
    setState(() => _isBusy = true);

    try {
      // ── Step 1: Try ABDM first for proper OTP-based identity verification ──
      // If ABDM is up and finds ABHA accounts linked to this mobile, we send
      // an OTP and the CHO must verify it before patient data is shown.
      bool abdmAvailable = false;
      try {
        final response = await BookingService.searchAbhaByMobile(mobile);
        if (!mounted) return;

        final data = (response['data'] is Map<String, dynamic>)
            ? response['data'] as Map<String, dynamic>
            : response;
        final accountsRaw = data['abhaList'] as List<dynamic>? ?? const [];
        final txnId = (data['txnId'] ?? '').toString();

        final accounts = accountsRaw
            .whereType<Map>()
            .map((raw) => _MobileAbhaAccount.fromMap(Map<String, dynamic>.from(raw)))
            .where((account) => account.index != null)
            .toList();

        if (accounts.isNotEmpty && txnId.isNotEmpty) {
          // ABDM found ABHA accounts — proceed with OTP verification.
          abdmAvailable = true;
          _mobileSearchTxnId = txnId;
          if (accounts.length == 1) {
            await _startMobileOtpFlow(accounts.first);
            return;
          }
          setState(() {
            _mobileAccounts = accounts;
            _showAccountDialog = true;
          });
          return;
        }
        // ABDM responded but found no ABHA for this mobile — fall through.
        abdmAvailable = true; // server replied, just no ABHA linked
      } on BookingApiException {
        // ABDM returned a business error (not timeout) — re-throw so
        // the outer catch can show the server's own error message.
        rethrow;
      } catch (_) {
        // ABDM timed out or network error — fall through to local DB below.
        debugPrint('⚠️ ABDM mobile search unavailable — falling back to local DB');
      }

      if (!mounted) return;

      // ── Step 2: ABDM fallback — check local DB ──────────────────────────────
      // If ABDM is unreachable (timeout / network error) OR the mobile has no
      // ABHA linked, check whether the patient already exists in our own DB.
      // The CHO is a trusted healthcare worker, so showing an existing record
      // when ABDM is unavailable is acceptable.
      final existingPatient = await BookingService.findPatientByMobile(mobile);
      if (!mounted) return;

      if (existingPatient != null) {
        setState(() {
          _patientPreview = _patientFromExistingPatient(
            existingPatient,
            sourceLabel: 'Mobile',
          );
        });
        _showSnack(
          abdmAvailable
              ? 'No ABHA linked to this mobile — showing existing patient record.'
              : 'ABDM unavailable — showing existing patient from local records.',
        );
        return;
      }

      // Nothing found anywhere.
      _showSnack(
        'No patient found for this mobile number. '
        'Use the Manual tab to register a new patient.',
      );
    } on BookingApiException catch (error) {
      _showSnack(error.message);
    } catch (_) {
      _showSnack('Mobile verification failed. Please try again.');
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _startAbhaVerification() async {
    final abha = _abhaController.text.trim();
    if (!RegExp(r'^\d{2}-\d{4}-\d{4}-\d{4}$').hasMatch(abha)) {
      _showSnack('Enter ABHA ID in format XX-XXXX-XXXX-XXXX.');
      return;
    }

    _clearTransientUi();
    setState(() => _isBusy = true);

    try {
      final existingPatient = await BookingService.findPatientByAbha(abha);
      if (!mounted) return;

      if (existingPatient != null) {
        setState(() {
          _patientPreview = _patientFromExistingPatient(
            existingPatient,
            sourceLabel: 'ABHA',
          );
        });
        _showSnack('Existing patient found for this ABHA ID.');
        return;
      }

      final accessToken = await BookingService.generateAbdmToken();
      final publicKey = await BookingService.generatePublicKey(accessToken);
      final txnId = await BookingService.sendAbhaOtp(
        abhaId: abha,
        publicKey: publicKey,
        accessToken: accessToken,
      );

      if (!mounted) return;
      setState(() {
        _abdmAccessToken = accessToken;
        _abdmPublicKey = publicKey;
        _otpTxnId = txnId;
        _otpFlow = _OtpFlow.abha;
        _otpController.clear();
        _showOtpDialog = true;
      });
      _showSnack('OTP sent for ABHA verification.');
    } on BookingApiException catch (error) {
      _showSnack(error.message);
    } catch (_) {
      _showSnack('Unable to start ABHA verification right now.');
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _verifyOtp() async {
    final otp = _otpController.text.trim();
    if (otp.length != 6) {
      _showSnack('Enter a valid 6-digit OTP.');
      return;
    }

    if (_otpFlow == null || _abdmAccessToken == null || _otpTxnId == null) {
      _showSnack('OTP session expired. Please start verification again.');
      return;
    }

    setState(() => _isBusy = true);

    try {
      if (_otpFlow == _OtpFlow.abha) {
        await _completeAbhaOtpFlow(otp);
      } else {
        await _completeMobileOtpFlow(otp);
      }
    } on BookingApiException catch (error) {
      _showSnack(error.message);
    } catch (_) {
      _showSnack('OTP verification failed. Please try again.');
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _registerManualPatient() async {
    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();
    final age = _ageController.text.trim();

    if (firstName.isEmpty || lastName.isEmpty || age.isEmpty || _gender == null) {
      _showSnack('Fill first name, last name, age and gender.');
      return;
    }

    _clearTransientUi();
    setState(() => _isBusy = true);

    try {
      final abhaId = _abhaManualController.text.trim();
      final payload = <String, dynamic>{
        'abha_id': abhaId.isEmpty ? _generateDummyAbhaId() : abhaId,
        'first_name': firstName,
        'last_name': lastName,
        'email': _emailController.text.trim().isEmpty
            ? 'example@example.com'
            : _emailController.text.trim(),
        'phone': _phoneController.text.trim(),
        'age': int.tryParse(age) ?? age,
        'gender': _normalizeGender(_gender!),
        'village': _villageController.text.trim(),
        'block': _blockController.text.trim(),
        'district': _districtController.text.trim(),
        'state': _stateController.text.trim(),
        'pincode': _pincodeController.text.trim(),
        'date_of_birth': _calculateDobFromAge(int.tryParse(age)),
        'fcmToken': _generateRandomFcmToken(),
        'source': abhaId.isEmpty ? 'non_abha' : 'manual_abha',
      };

      final registration = await BookingService.registerPatient(payload);
      if (!mounted) return;

      setState(() {
        _patientPreview = _PatientPreview(
          patientId: (registration['patient_id'] ?? '').toString(),
          name: '$firstName $lastName',
          age: age,
          gender: _gender!,
          phone: _phoneController.text.trim(),
          email: _emailController.text.trim(),
          abhaId: payload['abha_id'].toString(),
          sourceLabel: 'Manual',
        );
      });

      _showSnack('Patient registered successfully.');
    } on BookingApiException catch (error) {
      _showSnack(error.message);
    } catch (_) {
      _showSnack('Unable to register patient right now.');
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _continuePatientFlow() async {
    final patient = _patientPreview;
    if (patient == null || patient.patientId.isEmpty) {
      _showSnack('Patient ID missing. Please complete verification again.');
      return;
    }

    final vitalsPayload = _buildVitalsPayload();
    setState(() => _isBusy = true);
    try {
      if (vitalsPayload.isNotEmpty) {
        await BookingService.updatePatientVitals(patient.patientId, vitalsPayload);
      }

      if (!mounted) return;
      // Open the native doctor-listing page with this patient pre-selected.
      // The CHO can see all online doctors and tap "Consult Now" to start
      // the telemedicine flow — no web browser needed.
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => TelemedicinePage(
            patientId: int.tryParse(patient.patientId) ?? 0,
            patientName: patient.name,
            patientAbhaId: patient.abhaId,
          ),
        ),
      );
    } on BookingApiException catch (error) {
      _showSnack(error.message);
    } catch (_) {
      _showSnack('Unable to continue with this patient right now.');
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: GoogleFonts.inter(fontSize: 13, color: Colors.white),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F8FA),
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                _buildHeader(),
                _buildTabs(),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildMobileTab(),
                      _buildAbhaTab(),
                      _buildQrTab(),
                      _buildManualTab(),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: _buildCreateAbhaFooter(),
                ),
              ],
            ),
          ),
          if (_isBusy)
            Container(
              color: Colors.white.withValues(alpha: 0.7),
              child: const Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              ),
            ),
          if (_showAccountDialog) _buildAccountDialog(),
          if (_showOtpDialog) _buildOtpDialog(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        gradient: AppColors.headerGradient,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.pop(context),
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            padding: const EdgeInsets.all(6),
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.14),
            ),
            icon: const Icon(
              Icons.arrow_back_ios_new_rounded,
              color: Colors.white,
              size: 16,
            ),
          ),
          Expanded(
            child: Center(
              child: Text(
                'Book Appointment',
                style: GoogleFonts.poppins(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(width: 34),
        ],
      ),
    );
  }

  Widget _buildTabs() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: TabBar(
        controller: _tabController,
        indicatorColor: AppColors.primary,
        indicatorWeight: 3,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        labelColor: AppColors.primary,
        unselectedLabelColor: AppColors.textSecondary,
        labelStyle: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700),
        unselectedLabelStyle:
            GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w500),
        tabs: const [
          Tab(text: 'Mobile'),
          Tab(text: 'ABHA'),
          Tab(text: 'QR Scan'),
          Tab(text: 'Manual'),
        ],
      ),
    );
  }

  Widget _buildMobileTab() {
    return _BookingBody(
      child: Column(
        children: [
          _SectionCard(
            title: 'Mobile Verification',
            subtitle: 'Use patient mobile number to begin the booking flow.',
            child: Column(
              children: [
                _LabeledField(
                  label: 'Mobile Number',
                  child: TextField(
                    controller: _mobileController,
                    keyboardType: TextInputType.phone,
                    decoration: _inputDecoration('Enter 10-digit mobile number'),
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton(
                    onPressed: _verifyMobile,
                    child: const Text('Verify Mobile'),
                  ),
                ),
              ],
            ),
          ),
          if (_patientPreview != null) ...[
            const SizedBox(height: 14),
            _buildPatientCard(),
          ],
        ],
      ),
    );
  }

  Widget _buildAbhaTab() {
    return _BookingBody(
      child: Column(
        children: [
          _SectionCard(
            title: 'ABHA Verification',
            subtitle: 'Enter ABHA ID and verify through OTP.',
            child: Column(
              children: [
                _LabeledField(
                  label: 'ABHA ID',
                  child: TextField(
                    controller: _abhaController,
                    decoration: _inputDecoration('XX-XXXX-XXXX-XXXX'),
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton(
                    onPressed: _startAbhaVerification,
                    child: const Text('Verify ABHA'),
                  ),
                ),
              ],
            ),
          ),
          if (_patientPreview != null) ...[
            const SizedBox(height: 14),
            _buildPatientCard(),
          ],
        ],
      ),
    );
  }

  Widget _buildQrTab() {
    return _BookingBody(
      child: Column(
        children: [
          _SectionCard(
            title: 'QR Scan',
            subtitle: 'Use ABHA or Manual flow right now. Live QR capture is not connected yet.',
            child: Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FBFB),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.25),
                      style: BorderStyle.solid,
                    ),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        Icons.qr_code_scanner_rounded,
                        size: 56,
                        color: AppColors.primary,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'QR Flow',
                        style: GoogleFonts.poppins(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'This tab is reserved for live QR scanning. Until the camera scanner is added, use the ABHA tab for the same verification flow.',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          height: 1.5,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildManualTab() {
    return _BookingBody(
      child: Column(
        children: [
          _SectionCard(
            title: 'Patient Information',
            subtitle: 'Classic patient registration form without webview.',
            child: Column(
              children: [
                _responsivePair(
                  left: _LabeledField(
                    label: 'First Name',
                    child: TextField(
                      controller: _firstNameController,
                      decoration: _inputDecoration('First name'),
                    ),
                  ),
                  right: _LabeledField(
                    label: 'Last Name',
                    child: TextField(
                      controller: _lastNameController,
                      decoration: _inputDecoration('Last name'),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _responsivePair(
                  left: _LabeledField(
                    label: 'Phone',
                    child: TextField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      decoration: _inputDecoration('Phone number'),
                    ),
                  ),
                  right: _LabeledField(
                    label: 'Email',
                    child: TextField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: _inputDecoration('Email address'),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _responsivePair(
                  left: _LabeledField(
                    label: 'Age',
                    child: TextField(
                      controller: _ageController,
                      keyboardType: TextInputType.number,
                      decoration: _inputDecoration('Age'),
                    ),
                  ),
                  right: _LabeledField(
                    label: 'Gender',
                    child: DropdownButtonFormField<String>(
                      initialValue: _gender,
                      isExpanded: true,
                      decoration: _inputDecoration('Select gender'),
                      items: const [
                        DropdownMenuItem(value: 'Male', child: Text('Male')),
                        DropdownMenuItem(value: 'Female', child: Text('Female')),
                        DropdownMenuItem(value: 'Other', child: Text('Other')),
                      ],
                      onChanged: (value) => setState(() => _gender = value),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _LabeledField(
                  label: 'ABHA ID',
                  child: TextField(
                    controller: _abhaManualController,
                    decoration: _inputDecoration('Optional ABHA ID'),
                  ),
                ),
                const SizedBox(height: 14),
                _responsivePair(
                  left: _LabeledField(
                    label: 'Village',
                    child: TextField(
                      controller: _villageController,
                      decoration: _inputDecoration('Village'),
                    ),
                  ),
                  right: _LabeledField(
                    label: 'Block',
                    child: TextField(
                      controller: _blockController,
                      decoration: _inputDecoration('Block'),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _responsivePair(
                  left: _LabeledField(
                    label: 'District',
                    child: TextField(
                      controller: _districtController,
                      decoration: _inputDecoration('District'),
                    ),
                  ),
                  right: _LabeledField(
                    label: 'State',
                    child: TextField(
                      controller: _stateController,
                      decoration: _inputDecoration('State'),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _LabeledField(
                  label: 'Pincode',
                  child: TextField(
                    controller: _pincodeController,
                    keyboardType: TextInputType.number,
                    decoration: _inputDecoration('Pincode'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _SectionCard(
            title: 'Patient Vitals',
            subtitle: 'Optional but useful for a stronger consultation flow.',
            child: Column(
              children: [
                _responsivePair(
                  left: _LabeledField(
                    label: 'SpO2 (%)',
                    child: TextField(
                      controller: _spo2Controller,
                      keyboardType: TextInputType.number,
                      decoration: _inputDecoration('95-100'),
                    ),
                  ),
                  right: _LabeledField(
                    label: 'Temperature',
                    child: TextField(
                      controller: _temperatureController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: _inputDecoration('98.6'),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _responsivePair(
                  left: _LabeledField(
                    label: 'BP Systolic',
                    child: TextField(
                      controller: _bpSysController,
                      keyboardType: TextInputType.number,
                      decoration: _inputDecoration('120'),
                    ),
                  ),
                  right: _LabeledField(
                    label: 'BP Diastolic',
                    child: TextField(
                      controller: _bpDiaController,
                      keyboardType: TextInputType.number,
                      decoration: _inputDecoration('80'),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _responsivePair(
                  left: _LabeledField(
                    label: 'Height (cm)',
                    child: TextField(
                      controller: _heightController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: _inputDecoration('170'),
                    ),
                  ),
                  right: _LabeledField(
                    label: 'Weight (kg)',
                    child: TextField(
                      controller: _weightController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: _inputDecoration('65'),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _LabeledField(
                  label: 'Chief Complaints',
                  child: TextField(
                    controller: _complaintsController,
                    maxLines: 4,
                    decoration: _inputDecoration('Describe complaints or symptoms'),
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton(
                    onPressed: _registerManualPatient,
                    child: const Text('Register & Continue'),
                  ),
                ),
              ],
            ),
          ),
          if (_patientPreview != null) ...[
            const SizedBox(height: 14),
            _buildPatientCard(),
          ],
        ],
      ),
    );
  }

  Widget _buildPatientCard() {
    final patient = _patientPreview!;

    return _SectionCard(
      title: 'Patient Details',
      subtitle: '${patient.sourceLabel} flow',
      child: Column(
        children: [
          _InfoRow(label: 'Name', value: patient.name),
          _InfoRow(label: 'Age', value: '${patient.age} years'),
          _InfoRow(label: 'Gender', value: patient.gender),
          _InfoRow(label: 'Phone', value: patient.phone.isEmpty ? '—' : patient.phone),
          _InfoRow(label: 'Email', value: patient.email.isEmpty ? '—' : patient.email),
          _InfoRow(label: 'ABHA ID', value: patient.abhaId),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _continuePatientFlow,
              child: const Text('Continue'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOtpDialog() {
    return Container(
      color: Colors.black.withValues(alpha: 0.3),
      child: Center(
        child: Container(
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Material(
            color: Colors.transparent,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Enter OTP',
                  style: GoogleFonts.poppins(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _otpFlow == _OtpFlow.mobile
                      ? 'Enter the 6-digit OTP sent to the selected mobile-linked ABHA account.'
                      : 'Enter the 6-digit OTP sent for ABHA verification.',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _otpController,
                  keyboardType: TextInputType.number,
                  decoration: _inputDecoration('6-digit OTP'),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => setState(() {
                        _showOtpDialog = false;
                        _otpFlow = null;
                        _otpTxnId = null;
                      }),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      onPressed: _verifyOtp,
                      child: const Text('Verify'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCreateAbhaFooter() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        children: [
          Text(
            'Need to create a fresh ABHA account for the patient?',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 11.5,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: OutlinedButton(
              onPressed: _openCreateAbhaPage,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.primary),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                foregroundColor: AppColors.primary,
              ),
              child: Text(
                'Create ABHA Account',
                style: GoogleFonts.inter(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountDialog() {
    return Container(
      color: Colors.black.withValues(alpha: 0.3),
      child: Center(
        child: Container(
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Material(
            color: Colors.transparent,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Select ABHA Account',
                  style: GoogleFonts.poppins(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Multiple ABHA accounts were found for this mobile number.',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 16),
                ..._mobileAccounts.map(
                  (account) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: InkWell(
                      onTap: () async {
                        setState(() => _showAccountDialog = false);
                        await _startMobileOtpFlow(account);
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppColors.cardBorder),
                          color: const Color(0xFFF8FBFB),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              account.name.isEmpty ? 'ABHA Account' : account.name,
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              account.abhaNumber,
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => setState(() {
                      _showAccountDialog = false;
                      _mobileAccounts = const [];
                    }),
                    child: const Text('Cancel'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: GoogleFonts.inter(
        fontSize: 13,
        color: AppColors.textHint,
      ),
      filled: true,
      fillColor: const Color(0xFFF8FBFB),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: AppColors.cardBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.2),
      ),
    );
  }

  Widget _responsivePair({
    required Widget left,
    required Widget right,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final useSingleColumn = constraints.maxWidth < 360;
        if (useSingleColumn) {
          return Column(
            children: [
              left,
              const SizedBox(height: 14),
              right,
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: left),
            const SizedBox(width: 12),
            Expanded(child: right),
          ],
        );
      },
    );
  }

  Future<void> _startMobileOtpFlow(_MobileAbhaAccount account) async {
    final txnId = _mobileSearchTxnId;
    if (txnId == null || txnId.isEmpty || account.index == null) {
      _showSnack('Unable to start mobile OTP flow. Try verifying again.');
      return;
    }

    setState(() => _isBusy = true);
    try {
      final accessToken = await BookingService.generateAbdmToken();
      final newTxnId = await BookingService.sendMobileAbhaOtp(
        index: account.index!,
        txnId: txnId,
        accessToken: accessToken,
      );

      if (!mounted) return;
      setState(() {
        _abdmAccessToken = accessToken;
        _otpTxnId = newTxnId;
        _otpFlow = _OtpFlow.mobile;
        _otpController.clear();
        _showOtpDialog = true;
      });
      _showSnack('OTP sent to the selected ABHA account.');
    } on BookingApiException catch (error) {
      _showSnack(error.message);
    } catch (_) {
      _showSnack('Unable to start mobile OTP verification.');
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _completeAbhaOtpFlow(String otp) async {
    final verifyToken = await BookingService.verifyAbhaOtp(
      otp: otp,
      publicKey: _abdmPublicKey ?? '',
      txnId: _otpTxnId ?? '',
      accessToken: _abdmAccessToken ?? '',
    );
    final account = await BookingService.fetchAbhaAccount(
      accessToken: _abdmAccessToken ?? '',
      accountToken: verifyToken,
    );

    final abhaId = (account['ABHANumber'] ?? account['abhaId'] ?? '').toString();
    if (abhaId.isEmpty) {
      throw const BookingApiException('ABHA account data is incomplete.');
    }

    final existingPatient = await BookingService.findPatientByAbha(abhaId);
    if (existingPatient != null) {
      if (!mounted) return;
      setState(() {
        _showOtpDialog = false;
        _patientPreview = _patientFromExistingPatient(
          existingPatient,
          sourceLabel: 'ABHA',
        );
      });
      _showSnack('Patient verified successfully.');
      return;
    }

    final registration = await BookingService.registerPatient(
      _registrationPayloadFromAbhaAccount(account),
    );

    if (!mounted) return;
    setState(() {
      _showOtpDialog = false;
      _patientPreview = _patientFromAbhaAccount(
        account: account,
        patientId: (registration['patient_id'] ?? '').toString(),
        sourceLabel: 'ABHA',
      );
    });
    _showSnack('Patient verified and registered successfully.');
  }

  Future<void> _completeMobileOtpFlow(String otp) async {
    final response = await BookingService.verifyMobileAbhaOtp(
      otp: otp,
      txnId: _otpTxnId ?? '',
      accessToken: _abdmAccessToken ?? '',
    );

    final data = (response['data'] is Map<String, dynamic>)
        ? response['data'] as Map<String, dynamic>
        : response;
    final patientDetails = (data['patientDetails'] is Map<String, dynamic>)
        ? data['patientDetails'] as Map<String, dynamic>
        : null;

    if (patientDetails != null) {
      final abhaId =
          (patientDetails['ABHANumber'] ?? patientDetails['abhaId'] ?? '')
              .toString();
      if (abhaId.isEmpty) {
        throw const BookingApiException('Verified patient details are incomplete.');
      }

      final existingPatient = await BookingService.findPatientByAbha(abhaId);
      if (existingPatient != null) {
        if (!mounted) return;
        setState(() {
          _showOtpDialog = false;
          _patientPreview = _patientFromExistingPatient(
            existingPatient,
            sourceLabel: 'Mobile',
          );
        });
        _showSnack('Patient verified successfully.');
        return;
      }

      final registration = await BookingService.registerPatient(
        _registrationPayloadFromMobilePatient(patientDetails),
      );

      if (!mounted) return;
      setState(() {
        _showOtpDialog = false;
        _patientPreview = _patientFromMobilePatient(
          patientDetails: patientDetails,
          patientId: (registration['patient_id'] ?? '').toString(),
        );
      });
      _showSnack('Patient verified and registered successfully.');
      return;
    }

    throw const BookingApiException('No verified patient data returned from OTP.');
  }

  _PatientPreview _patientFromExistingPatient(
    Map<String, dynamic> patient, {
    required String sourceLabel,
  }) {
    final firstName = (patient['first_name'] ?? '').toString().trim();
    final lastName = (patient['last_name'] ?? '').toString().trim();
    final name = '$firstName $lastName'.trim();

    return _PatientPreview(
      patientId: (patient['patient_id'] ?? '').toString(),
      name: name.isEmpty ? 'Patient' : name,
      age: _resolveAge(patient),
      gender: _displayGender((patient['gender'] ?? '').toString()),
      phone: (patient['phone'] ?? '').toString(),
      email: (patient['email'] ?? '').toString(),
      abhaId: (patient['abha_id'] ?? 'Not Available').toString(),
      sourceLabel: sourceLabel,
    );
  }

  _PatientPreview _patientFromAbhaAccount({
    required Map<String, dynamic> account,
    required String patientId,
    required String sourceLabel,
  }) {
    final firstName = (account['firstName'] ?? '').toString().trim();
    final lastName = (account['lastName'] ?? '').toString().trim();
    return _PatientPreview(
      patientId: patientId,
      name: '$firstName $lastName'.trim(),
      age: _calculateAgeFromParts(
        account['dayOfBirth'],
        account['monthOfBirth'],
        account['yearOfBirth'],
      ),
      gender: _displayGender((account['gender'] ?? '').toString()),
      phone: (account['mobile'] ?? '').toString(),
      email: (account['email'] ?? '').toString(),
      abhaId: (account['ABHANumber'] ?? '').toString(),
      sourceLabel: sourceLabel,
    );
  }

  _PatientPreview _patientFromMobilePatient({
    required Map<String, dynamic> patientDetails,
    required String patientId,
  }) {
    final firstName = (patientDetails['firstName'] ?? '').toString().trim();
    final middleName = (patientDetails['middleName'] ?? '').toString().trim();
    final lastName = (patientDetails['lastName'] ?? '').toString().trim();
    final name = [firstName, middleName, lastName]
        .where((part) => part.isNotEmpty)
        .join(' ');

    return _PatientPreview(
      patientId: patientId,
      name: name.isEmpty
          ? (patientDetails['name'] ?? 'Patient').toString()
          : name,
      age: _calculateAgeFromParts(
        patientDetails['dayOfBirth'],
        patientDetails['monthOfBirth'],
        patientDetails['yearOfBirth'],
      ),
      gender: _displayGender((patientDetails['gender'] ?? '').toString()),
      phone: (patientDetails['mobile'] ?? '').toString(),
      email: '',
      abhaId: (patientDetails['ABHANumber'] ?? '').toString(),
      sourceLabel: 'Mobile',
    );
  }

  Map<String, dynamic> _registrationPayloadFromAbhaAccount(
    Map<String, dynamic> account,
  ) {
    return {
      'abha_id': (account['ABHANumber'] ?? '').toString(),
      'first_name': (account['firstName'] ?? '').toString(),
      'last_name': (account['lastName'] ?? '').toString(),
      'email': (account['email'] ?? '').toString().isEmpty
          ? 'example@example.com'
          : (account['email'] ?? '').toString(),
      'phone': (account['mobile'] ?? '').toString(),
      'age': int.tryParse(
            _calculateAgeFromParts(
              account['dayOfBirth'],
              account['monthOfBirth'],
              account['yearOfBirth'],
            ),
          ) ??
          0,
      'date_of_birth': _formatDobFromParts(
        account['dayOfBirth'],
        account['monthOfBirth'],
        account['yearOfBirth'],
      ),
      'gender': _normalizeGender((account['gender'] ?? '').toString()),
      'fcmToken': _generateRandomFcmToken(),
      'source': 'abha',
    };
  }

  Map<String, dynamic> _registrationPayloadFromMobilePatient(
    Map<String, dynamic> patientDetails,
  ) {
    return {
      'abha_id': (patientDetails['ABHANumber'] ?? '').toString(),
      'first_name': (patientDetails['firstName'] ?? '').toString(),
      'middle_name': (patientDetails['middleName'] ?? '').toString(),
      'last_name': (patientDetails['lastName'] ?? '').toString(),
      'email': 'example@example.com',
      'phone': (patientDetails['mobile'] ?? '').toString(),
      'age': int.tryParse(
            _calculateAgeFromParts(
              patientDetails['dayOfBirth'],
              patientDetails['monthOfBirth'],
              patientDetails['yearOfBirth'],
            ),
          ) ??
          0,
      'date_of_birth': _formatDobFromParts(
        patientDetails['dayOfBirth'],
        patientDetails['monthOfBirth'],
        patientDetails['yearOfBirth'],
      ),
      'gender': _normalizeGender((patientDetails['gender'] ?? '').toString()),
      'fcmToken': _generateRandomFcmToken(),
      'source': 'mobile_abha',
    };
  }

  Map<String, dynamic> _buildVitalsPayload() {
    final payload = <String, dynamic>{};
    if (_complaintsController.text.trim().isNotEmpty) {
      payload['chief_complaints'] = _complaintsController.text.trim();
    }
    if (double.tryParse(_spo2Controller.text.trim()) != null) {
      payload['spo2'] = double.parse(_spo2Controller.text.trim());
    }
    if (double.tryParse(_temperatureController.text.trim()) != null) {
      payload['temperature'] = double.parse(_temperatureController.text.trim());
    }
    if (int.tryParse(_bpSysController.text.trim()) != null &&
        int.tryParse(_bpDiaController.text.trim()) != null) {
      final sys = int.parse(_bpSysController.text.trim());
      final dia = int.parse(_bpDiaController.text.trim());
      payload['blood_pressure_systolic'] = sys;
      payload['blood_pressure_diastolic'] = dia;
      payload['blood_pressure'] = '$sys/$dia';
    }
    if (double.tryParse(_heightController.text.trim()) != null) {
      payload['height'] = double.parse(_heightController.text.trim());
    }
    if (double.tryParse(_weightController.text.trim()) != null) {
      payload['weight'] = double.parse(_weightController.text.trim());
    }

    final height = double.tryParse(_heightController.text.trim());
    final weight = double.tryParse(_weightController.text.trim());
    if (height != null && height > 0 && weight != null) {
      final bmi = weight / ((height / 100) * (height / 100));
      payload['bmi'] = bmi.toStringAsFixed(2);
    }
    return payload;
  }

  void _clearTransientUi() {
    setState(() {
      _patientPreview = null;
      _showOtpDialog = false;
      _showAccountDialog = false;
      _mobileAccounts = const [];
      _otpController.clear();
      _otpFlow = null;
      _abdmAccessToken = null;
      _abdmPublicKey = null;
      _otpTxnId = null;
    });
  }

  String _resolveAge(Map<String, dynamic> patient) {
    final age = patient['age'];
    if (age != null && age.toString().trim().isNotEmpty) {
      return age.toString();
    }
    final dob = (patient['date_of_birth'] ?? '').toString();
    if (dob.isEmpty) return '—';
    try {
      final birthDate = DateTime.parse(dob);
      final now = DateTime.now();
      var years = now.year - birthDate.year;
      if (now.month < birthDate.month ||
          (now.month == birthDate.month && now.day < birthDate.day)) {
        years--;
      }
      return years.toString();
    } catch (_) {
      return '—';
    }
  }

  String _calculateAgeFromParts(dynamic day, dynamic month, dynamic year) {
    final birthYear = int.tryParse('$year');
    final birthMonth = int.tryParse('$month');
    final birthDay = int.tryParse('$day');
    if (birthYear == null || birthMonth == null || birthDay == null) return '—';
    final dob = DateTime(birthYear, birthMonth, birthDay);
    final now = DateTime.now();
    var years = now.year - dob.year;
    if (now.month < dob.month || (now.month == dob.month && now.day < dob.day)) {
      years--;
    }
    return years.toString();
  }

  String _formatDobFromParts(dynamic day, dynamic month, dynamic year) {
    final birthYear = int.tryParse('$year');
    final birthMonth = int.tryParse('$month');
    final birthDay = int.tryParse('$day');
    if (birthYear == null || birthMonth == null || birthDay == null) {
      return _calculateDobFromAge(null);
    }
    return '${birthYear.toString().padLeft(4, '0')}-${birthMonth.toString().padLeft(2, '0')}-${birthDay.toString().padLeft(2, '0')}';
  }

  String _calculateDobFromAge(int? age) {
    final year = DateTime.now().year - (age ?? 0);
    return '$year-01-01';
  }

  String _generateRandomFcmToken() {
    final millis = DateTime.now().millisecondsSinceEpoch;
    return 'mobile_${millis.toRadixString(36)}';
  }

  String _generateDummyAbhaId() {
    final millis = DateTime.now().millisecondsSinceEpoch.toString();
    return '99-${millis.substring(millis.length - 12, millis.length - 8)}-${millis.substring(millis.length - 8, millis.length - 4)}-${millis.substring(millis.length - 4)}';
  }

  String _normalizeGender(String value) {
    switch (value.trim().toLowerCase()) {
      case 'm':
      case 'male':
        return 'male';
      case 'f':
      case 'female':
        return 'female';
      default:
        return 'other';
    }
  }

  String _displayGender(String value) {
    switch (_normalizeGender(value)) {
      case 'male':
        return 'Male';
      case 'female':
        return 'Female';
      default:
        return 'Other';
    }
  }

  Future<void> _openCreateAbhaPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CreateAbhaPage()),
    );
  }
}

class _BookingBody extends StatelessWidget {
  const _BookingBody({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      child: child,
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
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
          Text(
            title,
            style: GoogleFonts.poppins(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: GoogleFonts.inter(
              fontSize: 13,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}

class _LabeledField extends StatelessWidget {
  const _LabeledField({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.cardBorder)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
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

class _PatientPreview {
  const _PatientPreview({
    required this.patientId,
    required this.name,
    required this.age,
    required this.gender,
    required this.phone,
    required this.email,
    required this.abhaId,
    required this.sourceLabel,
  });

  final String patientId;
  final String name;
  final String age;
  final String gender;
  final String phone;
  final String email;
  final String abhaId;
  final String sourceLabel;
}

enum _OtpFlow { abha, mobile }

class _MobileAbhaAccount {
  const _MobileAbhaAccount({
    required this.index,
    required this.abhaNumber,
    required this.name,
  });

  factory _MobileAbhaAccount.fromMap(Map<String, dynamic> map) {
    return _MobileAbhaAccount(
      index: int.tryParse('${map['index']}'),
      abhaNumber: (map['ABHANumber'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
    );
  }

  final int? index;
  final String abhaNumber;
  final String name;
}

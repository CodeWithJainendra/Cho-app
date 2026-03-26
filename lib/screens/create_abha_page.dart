import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/abdm_service.dart';
import '../services/booking_service.dart';
import '../utils/constants.dart';
import '../utils/env_config.dart';
import 'dashboard_page.dart';

class CreateAbhaPage extends StatefulWidget {
  const CreateAbhaPage({super.key});

  @override
  State<CreateAbhaPage> createState() => _CreateAbhaPageState();
}

class _CreateAbhaPageState extends State<CreateAbhaPage>
    with WidgetsBindingObserver {
  final _patientNameController = TextEditingController();
  final _aadhaarController = TextEditingController();
  final _mobileController = TextEditingController();
  final _otpController = TextEditingController();

  String _authMethod = 'aadhaar';
  bool _linkRecords = false;
  bool _shareRecords = false;
  bool _publicHealthConsent = false;
  bool _workerConfirmed = false;
  bool _patientConfirmed = false;

  // ─── Face Auth State ──────────────────────────────────
  bool _isLoading = false;
  bool _isPolling = false;
  String? _currentTxnId;
  String? _authToken; // SAMAR token for face auth
  String? _abdmAccessToken; // ABDM token for OTP
  int _pollAttempt = 0;
  Timer? _pollTimer;

  // ─── Flow State ───────────────────────────────────────
  // IDLE → FACE_AUTH → OTP_SENT → REGISTERED
  String _flowState = 'IDLE';
  String? _otpTxnId;
  int _resendCountdown = 0;
  Timer? _resendTimer;

  // ─── Registered Patient Data ──────────────────────────
  Map<String, dynamic>? _patientData;
  String? _registeredPatientId;
  String? _registeredAbhaNumber;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _patientNameController.dispose();
    _aadhaarController.dispose();
    _mobileController.dispose();
    _otpController.dispose();
    _pollTimer?.cancel();
    _resendTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _currentTxnId != null &&
        _authToken != null &&
        _flowState == 'FACE_AUTH') {
      _autoCheckAfterResume();
    }
  }

  // ══════════════════════════════════════════════════════
  //  STEP 1: FACE AUTH FLOW
  // ══════════════════════════════════════════════════════

  Future<void> _startFaceAuthFlow() async {
    final aadhaar = _aadhaarController.text.trim();
    final mobile = _mobileController.text.trim();

    if (aadhaar.length != 12) {
      _showSnackBar('Please enter a valid 12-digit Aadhaar number');
      return;
    }
    if (mobile.length != 10) {
      _showSnackBar('Please enter a valid 10-digit mobile number');
      return;
    }

    setState(() {
      _isLoading = true;
      _flowState = 'FACE_AUTH';
      _currentTxnId = null;
    });

    try {
      _authToken = await BookingService.getSamarAuthToken();

      final txnId = await BookingService.getFaceAuthTxnId(
        authToken: _authToken!,
      );
      setState(() => _currentTxnId = txnId);

      final faceAuthUrl = EnvConfig.faceAuthUrl(txnId);

      final launchedPackage = await AbdmService.openAbdmApp(faceAuthUrl);

      if (launchedPackage != null) {
        setState(() => _isLoading = false);
        _showSnackBar('Complete face authentication in ABDM app');
      } else {
        setState(() {
          _isLoading = false;
          _flowState = 'IDLE';
        });
        if (mounted) _showAbdmNotInstalledDialog(txnId);
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _flowState = 'IDLE';
      });
      _showSnackBar('Face authentication failed: ${e.toString()}');
    }
  }

  Future<void> _autoCheckAfterResume() async {
    if (_currentTxnId == null || _authToken == null) return;
    final aadhaar = _aadhaarController.text.trim();
    final mobile = _mobileController.text.trim();

    setState(() => _isLoading = true);

    try {
      final result = await BookingService.checkFaceAuthStatus(
        txnId: _currentTxnId!,
        aadhaar: aadhaar,
        mobile: mobile,
        authToken: _authToken!,
      );

      if (_isFaceAuthComplete(result)) {
        await _onFaceAuthComplete(result);
      } else if (_isFaceAuthPending(result)) {
        _startPolling(_currentTxnId!, aadhaar, mobile);
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  bool _isFaceAuthComplete(Map<String, dynamic> data) {
    final status = (data['status'] ?? '').toString().toUpperCase();
    final message = (data['message'] ?? '').toString();

    if (status == 'COMPLETE' || status == 'SUCCESS') return true;
    if (message.toLowerCase().contains('already exist') ||
        message.toLowerCase().contains('created successfully')) {
      return true;
    }
    if (data.containsKey('tokens') || data.containsKey('ABHAProfile')) {
      return true;
    }
    final nested = data['data'];
    if (nested is Map<String, dynamic>) {
      final ns = (nested['status'] ?? '').toString().toUpperCase();
      if (ns == 'COMPLETE' || ns == 'SUCCESS') return true;
      if (nested.containsKey('tokens') || nested.containsKey('ABHAProfile')) {
        return true;
      }
    }
    if (data.containsKey('healthIdNumber') ||
        data.containsKey('ABHANumber') ||
        data.containsKey('abhaNumber') ||
        data.containsKey('healthId')) {
      return true;
    }
    return false;
  }

  bool _isFaceAuthPending(Map<String, dynamic> data) {
    final status = (data['status'] ?? '').toString().toUpperCase();
    if (status == 'PENDING') return true;
    final nested = data['data'];
    if (nested is Map<String, dynamic>) {
      if ((nested['status'] ?? '').toString().toUpperCase() == 'PENDING') {
        return true;
      }
    }
    return false;
  }

  void _startPolling(String txnId, String aadhaar, String mobile) {
    setState(() {
      _isPolling = true;
      _pollAttempt = 0;
    });

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      _pollAttempt++;
      if (_pollAttempt > 10) {
        timer.cancel();
        setState(() {
          _isPolling = false;
          _isLoading = false;
          _flowState = 'IDLE';
        });
        _showSnackBar('Face authentication timed out. Please try again.');
        return;
      }

      try {
        final result = await BookingService.checkFaceAuthStatus(
          txnId: txnId,
          aadhaar: aadhaar,
          mobile: mobile,
          authToken: _authToken!,
        );
        if (_isFaceAuthComplete(result)) {
          timer.cancel();
          await _onFaceAuthComplete(result);
        }
      } catch (_) {}
    });
  }

  // ══════════════════════════════════════════════════════
  //  STEP 2: FACE AUTH DONE → SEND AADHAAR OTP
  // ══════════════════════════════════════════════════════

  Future<void> _onFaceAuthComplete(Map<String, dynamic> faceAuthData) async {
    _pollTimer?.cancel();
    setState(() {
      _isPolling = false;
      _isLoading = true;
    });

    // Store any ABHA data we got from face auth
    _patientData = faceAuthData;

    try {
      // Get ABDM access token for OTP flow
      _abdmAccessToken = await BookingService.generateAbdmToken();

      // Send Aadhaar OTP
      final aadhaar = _aadhaarController.text.trim();
      final otpResponse = await BookingService.sendAadharAbhaOtp(
        aadhaar: aadhaar,
        accessToken: _abdmAccessToken!,
      );

      // Extract txnId from response
      _otpTxnId = (otpResponse['txnId'] ?? otpResponse['transaction_id'] ?? '')
          .toString();

      if (_otpTxnId == null || _otpTxnId!.isEmpty) {
        throw const BookingApiException(
            'Transaction ID missing in OTP response.');
      }

      setState(() {
        _isLoading = false;
        _flowState = 'OTP_SENT';
      });

      _startResendTimer();
      _showSnackBar('OTP sent to your Aadhaar-linked mobile number');
    } catch (e) {
      setState(() => _isLoading = false);

      // If OTP sending fails, still show the result popup from face auth
      final abhaNumber = _extractAbhaNumber(faceAuthData);
      if (abhaNumber != null) {
        _showAbhaResultPopup(
          isAlreadyExists: (faceAuthData['message'] ?? '')
              .toString()
              .toLowerCase()
              .contains('already exist'),
          abhaNumber: abhaNumber,
          abhaAddress: _extractAbhaAddress(faceAuthData),
        );
      } else {
        _showSnackBar('OTP send failed: ${e.toString()}');
        setState(() => _flowState = 'IDLE');
      }
    }
  }

  void _startResendTimer() {
    _resendCountdown = 60;
    _resendTimer?.cancel();
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _resendCountdown--);
      if (_resendCountdown <= 0) timer.cancel();
    });
  }

  Future<void> _resendOtp() async {
    if (_resendCountdown > 0) return;
    setState(() => _isLoading = true);

    try {
      _abdmAccessToken ??= await BookingService.generateAbdmToken();

      final aadhaar = _aadhaarController.text.trim();
      final otpResponse = await BookingService.sendAadharAbhaOtp(
        aadhaar: aadhaar,
        accessToken: _abdmAccessToken!,
      );

      _otpTxnId = (otpResponse['txnId'] ?? otpResponse['transaction_id'] ?? '')
          .toString();

      setState(() => _isLoading = false);
      _startResendTimer();
      _showSnackBar('OTP resent successfully');
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnackBar('Failed to resend OTP: ${e.toString()}');
    }
  }

  // ══════════════════════════════════════════════════════
  //  STEP 3: VERIFY OTP → REGISTER PATIENT
  // ══════════════════════════════════════════════════════

  Future<void> _verifyOtpAndRegister() async {
    final otp = _otpController.text.trim();
    if (otp.length != 6) {
      _showSnackBar('Please enter a valid 6-digit OTP');
      return;
    }

    setState(() => _isLoading = true);

    try {
      // Verify OTP
      final verifyData = await BookingService.verifyAadharAbhaOtp(
        otp: otp,
        txnId: _otpTxnId ?? '',
        accessToken: _abdmAccessToken ?? '',
      );

      // Merge face auth data + OTP verify data
      final mergedData = <String, dynamic>{
        if (_patientData != null) ..._patientData!,
        ...verifyData,
      };

      // Extract patient info
      final abhaNumber = _extractAbhaNumber(mergedData) ?? '';
      final firstName =
          (mergedData['firstName'] ?? mergedData['first_name'] ?? '')
              .toString();
      final lastName =
          (mergedData['lastName'] ?? mergedData['last_name'] ?? '').toString();
      final mobile = (mergedData['mobile'] ??
              mergedData['phone'] ??
              _mobileController.text.trim())
          .toString();
      final gender = (mergedData['gender'] ?? '').toString();
      final email = (mergedData['email'] ?? 'example@example.com').toString();

      final age = _calculateAgeFromParts(
        mergedData['dayOfBirth'],
        mergedData['monthOfBirth'],
        mergedData['yearOfBirth'],
      );
      final dob = _formatDobFromParts(
        mergedData['dayOfBirth'],
        mergedData['monthOfBirth'],
        mergedData['yearOfBirth'],
      );

      // Check if patient already exists
      final existingPatient = abhaNumber.isNotEmpty
          ? await BookingService.findPatientByAbha(abhaNumber)
          : null;

      String patientId;

      if (existingPatient != null) {
        patientId =
            (existingPatient['patient_id'] ?? existingPatient['id'] ?? '')
                .toString();
        _patientData = existingPatient;
      } else {
        // Register patient
        final payload = <String, dynamic>{
          'abha_id':
              abhaNumber.isNotEmpty ? abhaNumber : _generateDummyAbhaId(),
          'first_name': firstName.isNotEmpty
              ? firstName
              : _patientNameController.text.trim().split(' ').first,
          'last_name': lastName.isNotEmpty
              ? lastName
              : (_patientNameController.text.trim().split(' ').length > 1
                  ? _patientNameController.text.trim().split(' ').last
                  : ''),
          'email': email.isEmpty ? 'example@example.com' : email,
          'phone': mobile.isNotEmpty ? mobile : _mobileController.text.trim(),
          'age': int.tryParse(age) ?? 0,
          'gender': _normalizeGender(gender),
          'date_of_birth': dob,
          'fcmToken': _generateRandomFcmToken(),
          'source': 'abha',
        };

        final registration = await BookingService.registerPatient(payload);
        patientId = (registration['patient_id'] ?? '').toString();
        _patientData = mergedData;
      }

      setState(() {
        _isLoading = false;
        _flowState = 'REGISTERED';
        _registeredPatientId = patientId;
        _registeredAbhaNumber = abhaNumber;
      });

      _showSnackBar('Patient registered successfully!');
    } on BookingApiException catch (e) {
      setState(() => _isLoading = false);
      _showSnackBar(e.message);
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnackBar('Verification failed: ${e.toString()}');
    }
  }

  // ══════════════════════════════════════════════════════
  //  CONTINUE → DASHBOARD
  // ══════════════════════════════════════════════════════

  void _onContinueToDashboard() {
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const DashboardPage()),
      (route) => false,
    );
  }

  // ══════════════════════════════════════════════════════
  //  MAIN CONTINUE BUTTON HANDLER
  // ══════════════════════════════════════════════════════

  void _onContinuePressed() {
    if (_flowState == 'IDLE' && !_validateRequiredSelections()) {
      return;
    }

    if (_authMethod == 'face') {
      switch (_flowState) {
        case 'FACE_AUTH':
          _autoCheckAfterResume();
          break;
        case 'OTP_SENT':
          _verifyOtpAndRegister();
          break;
        case 'REGISTERED':
          _onContinueToDashboard();
          break;
        default:
          _startFaceAuthFlow();
      }
    } else {
      _startAadhaarOtpFlow();
    }
  }

  void _startAadhaarOtpFlow() {
    _showSnackBar(
        'ABHA creation via Aadhaar OTP is ready. API submission can be connected next.');
  }

  bool _validateRequiredSelections() {
    final patientName = _patientNameController.text.trim();
    final aadhaar = _aadhaarController.text.trim();
    final mobile = _mobileController.text.trim();

    if (patientName.isEmpty) {
      _showSnackBar('Please enter patient name.');
      return false;
    }
    if (mobile.length != 10) {
      _showSnackBar('Please enter a valid 10-digit mobile number.');
      return false;
    }
    if (aadhaar.length != 12) {
      _showSnackBar('Please enter a valid 12-digit Aadhaar number.');
      return false;
    }

    if (!_linkRecords ||
        !_shareRecords ||
        !_publicHealthConsent ||
        !_workerConfirmed ||
        !_patientConfirmed) {
      _showSnackBar(
          'Please select all required consent checkboxes to continue.');
      return false;
    }
    return true;
  }

  // ══════════════════════════════════════════════════════
  //  HELPERS
  // ══════════════════════════════════════════════════════

  String? _extractAbhaNumber(Map<String, dynamic> data) {
    final direct = data['ABHANumber'] ??
        data['abhaNumber'] ??
        data['healthIdNumber'] ??
        data['healthId'];
    if (direct != null) return direct.toString();
    final profile = data['ABHAProfile'];
    if (profile is Map<String, dynamic>) {
      final p = profile['ABHANumber'] ??
          profile['abhaNumber'] ??
          profile['healthIdNumber'] ??
          profile['healthId'];
      if (p != null) return p.toString();
    }
    final nested = data['data'];
    if (nested is Map<String, dynamic>) return _extractAbhaNumber(nested);
    return null;
  }

  String? _extractAbhaAddress(Map<String, dynamic> data) {
    final direct = data['ABHAAddress'] ??
        data['abhaAddress'] ??
        data['healthId'] ??
        data['phrAddress'];
    if (direct != null) return direct.toString();
    final profile = data['ABHAProfile'];
    if (profile is Map<String, dynamic>) {
      final p = profile['ABHAAddress'] ??
          profile['abhaAddress'] ??
          profile['healthId'] ??
          profile['phrAddress'];
      if (p != null) return p.toString();
    }
    final nested = data['data'];
    if (nested is Map<String, dynamic>) return _extractAbhaAddress(nested);
    return null;
  }

  String _calculateAgeFromParts(dynamic day, dynamic month, dynamic year) {
    final birthYear = int.tryParse('$year');
    final birthMonth = int.tryParse('$month');
    final birthDay = int.tryParse('$day');
    if (birthYear == null || birthMonth == null || birthDay == null) return '0';
    final dob = DateTime(birthYear, birthMonth, birthDay);
    final now = DateTime.now();
    var years = now.year - dob.year;
    if (now.month < dob.month ||
        (now.month == dob.month && now.day < dob.day)) {
      years--;
    }
    return years.toString();
  }

  String _formatDobFromParts(dynamic day, dynamic month, dynamic year) {
    final birthYear = int.tryParse('$year');
    final birthMonth = int.tryParse('$month');
    final birthDay = int.tryParse('$day');
    if (birthYear == null || birthMonth == null || birthDay == null) {
      return '${DateTime.now().year}-01-01';
    }
    return '${birthYear.toString().padLeft(4, '0')}-${birthMonth.toString().padLeft(2, '0')}-${birthDay.toString().padLeft(2, '0')}';
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

  String _generateRandomFcmToken() {
    final millis = DateTime.now().millisecondsSinceEpoch;
    return 'mobile_${millis.toRadixString(36)}';
  }

  String _generateDummyAbhaId() {
    final millis = DateTime.now().millisecondsSinceEpoch.toString();
    return '99-${millis.substring(millis.length - 12, millis.length - 8)}-${millis.substring(millis.length - 8, millis.length - 4)}-${millis.substring(millis.length - 4)}';
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: GoogleFonts.inter(fontSize: 13)),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showAbdmNotInstalledDialog(String txnId) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'ABDM App Required',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 18),
        ),
        content: Text(
          'ABDM App is not installed on your device. Please install it from Play Store to continue with face authentication.',
          style: GoogleFonts.inter(fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              AbdmService.openPlayStore();
            },
            child: const Text('Install from Play Store'),
          ),
        ],
      ),
    );
  }

  void _showAbhaResultPopup({
    required bool isAlreadyExists,
    String? abhaNumber,
    String? abhaAddress,
  }) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: isAlreadyExists
                      ? const Color(0xFFFFF3E0)
                      : const Color(0xFFE8F5E9),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isAlreadyExists
                      ? Icons.info_rounded
                      : Icons.check_circle_rounded,
                  size: 40,
                  color: isAlreadyExists
                      ? const Color(0xFFE65100)
                      : const Color(0xFF2E7D32),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                isAlreadyExists
                    ? 'Account Already Exists'
                    : 'ABHA Account Created',
                style: GoogleFonts.poppins(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                isAlreadyExists
                    ? 'An ABHA account already exists for this Aadhaar number.'
                    : 'Face authentication completed successfully!',
                style: GoogleFonts.inter(
                    fontSize: 14, height: 1.5, color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
              if (abhaNumber != null) ...[
                const SizedBox(height: 20),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F8FA),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFD5EBEF)),
                  ),
                  child: Column(
                    children: [
                      Text('ABHA Number',
                          style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textSecondary)),
                      const SizedBox(height: 8),
                      GestureDetector(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: abhaNumber));
                          _showSnackBar('ABHA Number copied!');
                        },
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // FittedBox prevents long ABHA numbers from
                            // overflowing the card — scales down if needed.
                            Flexible(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  abhaNumber,
                                  style: GoogleFonts.poppins(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.primary,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(Icons.copy_rounded,
                                size: 18,
                                color:
                                    AppColors.primary.withValues(alpha: 0.6)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: () {
                    // Close the popup and switch to the REGISTERED state so
                    // _buildRegisteredPatientCard() is shown with full patient
                    // details.  The bottom bar then shows "Continue to Dashboard".
                    Navigator.pop(ctx);
                    setState(() {
                      _flowState = 'REGISTERED';
                      // Preserve the ABHA number so the patient card can show it.
                      if (abhaNumber != null) {
                        _registeredAbhaNumber ??= abhaNumber;
                      }
                    });
                  },
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.person_rounded, size: 18),
                      const SizedBox(width: 8),
                      Text('View Patient',
                          style: GoogleFonts.poppins(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════
  //  BUILD
  // ══════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final patientName = _displayPatientName;

    return Scaffold(
      backgroundColor: const Color(0xFFF3F8FA),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        centerTitle: true,
        titleSpacing: 0,
        leadingWidth: 72,
        leading: Padding(
          padding: const EdgeInsets.only(left: 16, top: 10, bottom: 10),
          child: IconButton(
            onPressed: () {
              _pollTimer?.cancel();
              _resendTimer?.cancel();
              Navigator.of(context).maybePop();
            },
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFFF7FAFC),
              foregroundColor: AppColors.textPrimary,
              side: const BorderSide(color: Color(0xFFD5E2E8)),
              elevation: 0,
            ),
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                size: 18, color: AppColors.textPrimary),
          ),
        ),
        title: Text(
          'Create ABHA Account',
          style: GoogleFonts.dmSans(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.primary),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 14),
        child: SizedBox(
          height: 48,
          child: ElevatedButton(
            onPressed: _isLoading || _isPolling ? null : _onContinuePressed,
            child: _isLoading || _isPolling
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      ),
                      const SizedBox(width: 12),
                      Text(_isPolling
                          ? 'Verifying... ($_pollAttempt/10)'
                          : 'Processing...'),
                    ],
                  )
                : Text(_continueButtonText),
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ─── OTP Entry Section (visible after face auth) ──
                if (_flowState == 'OTP_SENT') _buildOtpSection(),

                // ─── Patient Details (visible after registration) ──
                if (_flowState == 'REGISTERED') _buildRegisteredPatientCard(),

                // ─── Main Form (hidden after registration) ──
                if (_flowState != 'REGISTERED') ...[
                  _ClassicSection(
                    title: 'Patient Details',
                    subtitle:
                        'Enter the patient identity details required for ABHA creation.',
                    child: Column(
                      children: [
                        _buildResponsivePair(
                          left: _buildField(
                            label: 'Patient Name',
                            child: TextField(
                              controller: _patientNameController,
                              onChanged: (_) => setState(() {}),
                              decoration: _decoration('Enter patient name'),
                              enabled: _flowState == 'IDLE',
                            ),
                          ),
                          right: _buildField(
                            label: 'Mobile Number',
                            child: TextField(
                              controller: _mobileController,
                              keyboardType: TextInputType.phone,
                              decoration: _decoration('Enter mobile number'),
                              enabled: _flowState == 'IDLE',
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        _buildField(
                          label: 'Aadhaar Number',
                          child: TextField(
                            controller: _aadhaarController,
                            keyboardType: TextInputType.number,
                            decoration: _decoration('Enter Aadhaar number'),
                            enabled: _flowState == 'IDLE',
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _ClassicSection(
                    title: 'Authentication Method',
                    subtitle:
                        'Choose how the beneficiary will complete identity verification.',
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final vertical = constraints.maxWidth < 560;
                        final aadhaarChoice = _AuthChoice(
                          selected: _authMethod == 'aadhaar',
                          icon: Icons.phone_android_rounded,
                          title: 'Aadhaar OTP',
                          description:
                              'Recommended for standard ABHA onboarding.',
                          onTap: _flowState == 'IDLE'
                              ? () => setState(() => _authMethod = 'aadhaar')
                              : () {},
                        );
                        final faceChoice = _AuthChoice(
                          selected: _authMethod == 'face',
                          icon: Icons.face_retouching_natural_rounded,
                          title: 'Face Authentication',
                          description:
                              'Opens ABDM app for device-assisted face verification.',
                          onTap: _flowState == 'IDLE'
                              ? () => setState(() => _authMethod = 'face')
                              : () {},
                        );

                        if (vertical) {
                          return Column(children: [
                            aadhaarChoice,
                            const SizedBox(height: 10),
                            faceChoice
                          ]);
                        }
                        return Row(children: [
                          Expanded(child: aadhaarChoice),
                          const SizedBox(width: 10),
                          Expanded(child: faceChoice)
                        ]);
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  _ClassicSection(
                    title: 'Consent Declaration',
                    subtitle:
                        'Review and confirm the mandatory declarations before proceeding.',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FCFD),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: const Color(0xFFD9EEF2)),
                          ),
                          child: Text(
                            'I, $patientName, hereby declare that:',
                            style: GoogleFonts.inter(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const _ConsentParagraph(
                          text:
                              'I am voluntarily sharing my Aadhaar Number / Virtual ID issued by the Unique Identification Authority of India ("UIDAI"), and my demographic information for the purpose of creating an Ayushman Bharat Health Account number ("ABHA number") and Ayushman Bharat Health Account address ("ABHA Address"). I authorize NHA to use my Aadhaar number / Virtual ID for performing Aadhaar based authentication with UIDAI as per the provisions of the Aadhaar (Targeted Delivery of Financial and other Subsidies, Benefits and Services) Act, 2016 for the aforesaid purpose. I understand that UIDAI will share my e-KYC details, or response of "Yes" with NHA upon successful authentication.',
                        ),
                        const SizedBox(height: 10),
                        const _DisabledConsentTile(
                          text:
                              'I intend to create Ayushman Bharat Health Account Number ("ABHA number") and Ayushman Bharat Health Account address ("ABHA Address") using document other than Aadhaar. (This option is disabled for Aadhaar-based creation)',
                        ),
                        const SizedBox(height: 8),
                        _ConsentCheckTile(
                            value: _linkRecords,
                            text:
                                'I consent to usage of my ABHA address and ABHA number for linking of my legacy (past) health records and those which will be generated during this encounter.',
                            onChanged: (v) =>
                                setState(() => _linkRecords = v ?? false)),
                        _ConsentCheckTile(
                            value: _shareRecords,
                            text:
                                'I authorize the sharing of all my health records with healthcare provider(s) for the purpose of providing healthcare services to me during this encounter.',
                            onChanged: (v) =>
                                setState(() => _shareRecords = v ?? false)),
                        _ConsentCheckTile(
                            value: _publicHealthConsent,
                            text:
                                'I consent to the anonymization and subsequent use of my health records for public health purposes.',
                            onChanged: (v) => setState(
                                () => _publicHealthConsent = v ?? false)),
                        _ConsentCheckTile(
                            value: _workerConfirmed,
                            text:
                                'I, (healthcare worker), confirm that I have duly informed and explained the beneficiary of the contents of consent for aforementioned purposes.',
                            onChanged: (v) =>
                                setState(() => _workerConfirmed = v ?? false)),
                        _ConsentCheckTile(
                            value: _patientConfirmed,
                            text:
                                'I, $patientName, have been explained about the consent as stated above and hereby provide my consent for the aforementioned purposes.',
                            onChanged: (v) =>
                                setState(() => _patientConfirmed = v ?? false)),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 84),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─── OTP Section Widget ───────────────────────────────
  Widget _buildOtpSection() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: _ClassicSection(
        title: 'Enter OTP',
        subtitle: 'OTP has been sent to your Aadhaar-linked mobile number.',
        child: Column(
          children: [
            TextField(
              controller: _otpController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              style: GoogleFonts.dmSans(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                letterSpacing: 6,
                color: AppColors.textPrimary,
              ),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                hintText: '------',
                hintStyle: GoogleFonts.dmSans(
                  fontSize: 20,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 6,
                  color: AppColors.textHint,
                ),
                counterText: '',
                filled: true,
                fillColor: const Color(0xFFFBFDFE),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: Color(0xFFD5EBEF)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: Color(0xFFD5EBEF)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide:
                      const BorderSide(color: AppColors.primary, width: 1.3),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_resendCountdown > 0)
                  Text(
                    'Resend OTP in ${_resendCountdown}s',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  )
                else
                  TextButton(
                    onPressed: _resendOtp,
                    child: Text(
                      'Resend OTP',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ─── Registered Patient Card ──────────────────────────
  Widget _buildRegisteredPatientCard() {
    final data = _patientData ?? {};
    final firstName =
        (data['firstName'] ?? data['first_name'] ?? data['name'] ?? '')
            .toString();
    final lastName = (data['lastName'] ?? data['last_name'] ?? '').toString();
    final name = '$firstName $lastName'.trim();
    final displayName =
        name.isNotEmpty ? name : _patientNameController.text.trim();
    final mobile =
        (data['mobile'] ?? data['phone'] ?? _mobileController.text.trim())
            .toString();
    final gender = _displayGender((data['gender'] ?? '').toString());
    final age = _calculateAgeFromParts(
        data['dayOfBirth'], data['monthOfBirth'], data['yearOfBirth']);
    final abhaId = _registeredAbhaNumber ?? _extractAbhaNumber(data) ?? '';

    // Subtitle reflects whether the ABHA account was newly created or already existed.
    final isExisting = (data['message'] ?? '')
            .toString()
            .toLowerCase()
            .contains('already exist') ||
        _registeredPatientId != null;
    final subtitle = isExisting
        ? 'Existing ABHA account found for this patient.'
        : 'ABHA account created successfully.';

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      child: _ClassicSection(
        title: 'Patient Details',
        subtitle: subtitle,
        child: Column(
          children: [
            // Success indicator
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFE8F5E9),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF81C784)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle,
                      color: Color(0xFF2E7D32), size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Patient registered successfully',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF2E7D32),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Patient info grid
            _buildInfoRow('Name:', displayName),
            _buildInfoRow('Age:', age != '0' ? '$age years' : '—'),
            _buildInfoRow('Gender:', gender),
            _buildInfoRow('Phone:', mobile.isNotEmpty ? '+91$mobile' : '—'),
            if (abhaId.isNotEmpty) _buildInfoRow('ABHA ID:', abhaId),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: label == 'ABHA ID:' && value.isNotEmpty
                  ? () {
                      Clipboard.setData(ClipboardData(text: value));
                      _showSnackBar('Copied $value');
                    }
                  : null,
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      value,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  if (label == 'ABHA ID:' && value.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.copy_rounded,
                        size: 14,
                        color: AppColors.primary.withValues(alpha: 0.6)),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String get _continueButtonText {
    switch (_flowState) {
      case 'FACE_AUTH':
        return 'Check Status';
      case 'OTP_SENT':
        return 'Verify OTP';
      case 'REGISTERED':
        return 'Continue to Dashboard';
      default:
        return 'Continue';
    }
  }

  String get _displayPatientName {
    final value =
        _patientNameController.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    return value.isEmpty ? '[Patient Name]' : value;
  }

  Widget _buildField({required String label, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: GoogleFonts.inter(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary)),
        const SizedBox(height: 6),
        child,
      ],
    );
  }

  Widget _buildResponsivePair({required Widget left, required Widget right}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          return Column(children: [left, const SizedBox(height: 12), right]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: left),
            const SizedBox(width: 12),
            Expanded(child: right)
          ],
        );
      },
    );
  }

  InputDecoration _decoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle:
          GoogleFonts.inter(fontSize: 12, color: AppColors.textSecondary),
      filled: true,
      fillColor: const Color(0xFFFBFDFE),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: Color(0xFFD5EBEF))),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: Color(0xFFD5EBEF))),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.2)),
      disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: Color(0xFFE8EEF0))),
    );
  }
}

// ═══════════════════════════════════════════════════════
//  REUSABLE WIDGETS
// ═══════════════════════════════════════════════════════

class _ClassicSection extends StatelessWidget {
  const _ClassicSection(
      {required this.title, required this.subtitle, required this.child});
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFDCEBF0)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 10,
              offset: const Offset(0, 4))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: GoogleFonts.dmSans(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          Text(subtitle,
              style: GoogleFonts.inter(
                  fontSize: 11.5, height: 1.4, color: AppColors.textSecondary)),
          const SizedBox(height: 13),
          child,
        ],
      ),
    );
  }
}

class _AuthChoice extends StatelessWidget {
  const _AuthChoice(
      {required this.selected,
      required this.icon,
      required this.title,
      required this.description,
      required this.onTap});
  final bool selected;
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentSoft : const Color(0xFFFCFEFF),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: selected ? AppColors.primary : const Color(0xFFDCE8EC),
              width: selected ? 1.8 : 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 18,
                color: selected ? AppColors.primary : AppColors.textHint),
            const SizedBox(width: 8),
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: selected
                    ? AppColors.primary.withValues(alpha: 0.12)
                    : const Color(0xFFF1F6F8),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon,
                  size: 16,
                  color:
                      selected ? AppColors.primary : AppColors.textSecondary),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: GoogleFonts.dmSans(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: selected
                              ? AppColors.primary
                              : AppColors.textPrimary)),
                  const SizedBox(height: 3),
                  Text(description,
                      style: GoogleFonts.inter(
                          fontSize: 10.8,
                          height: 1.35,
                          color: AppColors.textSecondary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConsentParagraph extends StatelessWidget {
  const _ConsentParagraph({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: GoogleFonts.inter(
            fontSize: 11.5, height: 1.55, color: AppColors.textSecondary));
  }
}

class _DisabledConsentTile extends StatelessWidget {
  const _DisabledConsentTile({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.46,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFF7FAFB),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE5EEF1)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Transform.scale(
                scale: 0.9, child: Checkbox(value: false, onChanged: null)),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(text,
                    style: GoogleFonts.inter(
                        fontSize: 11.5,
                        height: 1.55,
                        color: AppColors.textSecondary)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConsentCheckTile extends StatelessWidget {
  const _ConsentCheckTile(
      {required this.value, required this.text, required this.onChanged});
  final bool value;
  final String text;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFBFDFE),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: value
              ? AppColors.primary.withValues(alpha: 0.4)
              : const Color(0xFFE3EDF0),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Transform.scale(
            scale: 0.92,
            child: Checkbox(
              value: value,
              onChanged: onChanged,
              activeColor: AppColors.primary,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6)),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(text,
                  style: GoogleFonts.inter(
                      fontSize: 11.5,
                      height: 1.5,
                      color: AppColors.textPrimary)),
            ),
          ),
        ],
      ),
    );
  }
}

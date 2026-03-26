import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'booking_service.dart';

class TelemedicineNotificationService {
  TelemedicineNotificationService._();
  static final TelemedicineNotificationService instance =
      TelemedicineNotificationService._();

  static const FirebaseOptions _firebaseOptions = FirebaseOptions(
    apiKey: 'AIzaSyBExR3L8x6uZFTiExzYPRUI2qPNyyCZp4Y',
    appId: '1:824249876716:web:1c6a362933b5623f5265c9',
    messagingSenderId: '824249876716',
    projectId: 'healthstack-6bc78',
    authDomain: 'healthstack-6bc78.firebaseapp.com',
    storageBucket: 'healthstack-6bc78.firebasestorage.app',
    measurementId: 'G-C1KD80ZLQ2',
  );

  FirebaseApp? _app;
  FirebaseFirestore? _db;

  Future<FirebaseFirestore> _ensureDb() async {
    if (_db != null) return _db!;

    try {
      _app = Firebase.apps.isNotEmpty
          ? Firebase.app()
          : await Firebase.initializeApp(options: _firebaseOptions);
      _db = FirebaseFirestore.instanceFor(app: _app!);
      return _db!;
    } catch (e) {
      debugPrint('❌ TelemedNotification: Firebase init failed: $e');
      rethrow;
    }
  }

  Future<String> sendNotificationToDoctor({
    required int doctorId,
    required int patientId,
    required int choId,
    String? message,
  }) async {
    debugPrint(
      '📤 TelemedNotification: sending doctorId=$doctorId patientId=$patientId choId=$choId',
    );
    final db = await _ensureDb();

    // Doctor web listener opens every existing `pending` doc for that doctor.
    // If stale pending requests remain, the dialog can open an old patient
    // instead of the latest one. Cancel old CHO-originated requests first so
    // the current notification is the only active pending request.
    try {
      final staleDocs = await db
          .collection('notifications')
          .where('doctorId', isEqualTo: doctorId)
          .where('choId', isEqualTo: choId.toString())
          .where('status', isEqualTo: 'pending')
          .get()
          .timeout(const Duration(seconds: 8));

      for (final doc in staleDocs.docs) {
        await doc.reference.update({
          'status': 'cancelled',
          'success': false,
          'cancelReason': 'superseded_by_new_request',
          'responseTimestamp': FieldValue.serverTimestamp(),
        });
      }

      if (staleDocs.docs.isNotEmpty) {
        debugPrint(
          '🧹 TelemedNotification: cancelled ${staleDocs.docs.length} stale pending docs '
          'for doctorId=$doctorId choId=$choId',
        );
      }
    } catch (e) {
      debugPrint('⚠️ TelemedNotification: stale pending cleanup failed: $e');
    }

    final payload = <String, dynamic>{
      'doctorId': doctorId,
      'patientId': patientId.toString(),
      'choId': choId.toString(),
      'message': message ??
          'Patient is requesting an immediate consultation with medical history consent granted',
      'status': 'pending',
      'success': false,
      'timestamp': FieldValue.serverTimestamp(),
    };

    final docRef = await db.collection('notifications').add(payload).timeout(
      const Duration(seconds: 12),
      onTimeout: () => throw TimeoutException(
        'Timed out while sending consultation notification',
      ),
    );
    debugPrint('✅ TelemedNotification: sent docId=${docRef.id}');

    // Match the older working CHO frontend: notification write first, then
    // grant patient access as a non-blocking side-effect.
    try {
      final accessData = await BookingService.grantPatientAccess(
        doctorId: doctorId,
        patientId: patientId,
      );
      debugPrint('✅ TelemedNotification: patient access granted: $accessData');
    } catch (e) {
      debugPrint('⚠️ TelemedNotification: grantPatientAccess failed: $e');
    }

    return docRef.id;
  }

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>> waitForDoctorResponse(
    String notificationId, {
    required void Function(bool accepted, Map<String, dynamic> data, String? status)
        onResponse,
  }) {
    return _ensureDb().asStream().asyncExpand((db) {
      return db.collection('notifications').doc(notificationId).snapshots();
    }).listen((snapshot) {
      if (!snapshot.exists) return;
      final data = snapshot.data() ?? <String, dynamic>{};
      final success = data['success'] == true;
      final status = (data['status'] ?? '').toString().trim().toLowerCase();
      final nested = data['data'];

      String nestedRoomId = '';
      String nestedAppointmentId = '';
      if (nested is Map<String, dynamic>) {
        nestedRoomId =
            (nested['roomId'] ?? nested['room_id'] ?? '').toString().trim();
        nestedAppointmentId = (nested['appointmentId'] ??
                nested['appointment_id'] ??
                '')
            .toString()
            .trim();
      }

      final accepted = success ||
          status == 'accepted' ||
          status == 'approved' ||
          (nestedRoomId.isNotEmpty) ||
          (nestedAppointmentId.isNotEmpty);

      final rejected = status == 'rejected' ||
          status == 'declined' ||
          status == 'cancelled' ||
          status == 'error';

      if (accepted) {
        debugPrint('✅ TelemedNotification: doctor accepted '
            'success=$success status=$status roomId=$nestedRoomId apptId=$nestedAppointmentId');
        onResponse(true, data, status);
      } else if (rejected) {
        debugPrint('⚠️ TelemedNotification: doctor response status=$status');
        onResponse(false, data, status);
      } else {
        debugPrint('⏳ TelemedNotification: pending snapshot '
            'success=$success status=$status roomId=$nestedRoomId apptId=$nestedAppointmentId');
      }
    });
  }

  Future<Map<String, dynamic>?> getNotificationData(String notificationId) async {
    final db = await _ensureDb();
    final snapshot = await db.collection('notifications').doc(notificationId).get();
    if (!snapshot.exists) return null;
    return snapshot.data();
  }

  /// Expose the Firestore instance so other parts of the app can attach
  /// their own listeners (e.g. prescription updates in the video call screen).
  Future<FirebaseFirestore> getFirestore() => _ensureDb();
}

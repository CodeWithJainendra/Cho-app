class Appointment {
  final int? id;
  final String? patientName;
  final String? patientPhone;
  final String? patientEmail;
  final String? appointmentDate;
  final String? appointmentTime;
  final String? status;
  final String? reason;
  final String? doctorName;
  final String? villageName;
  final String? subCenter;
  final String? choName;
  final int? choId;
  final String? notes;
  final String? createdAt;
  final String? updatedAt;
  final String? gender;
  final int? age;
  final String? address;
  final String? tokenNumber;
  final String? appointmentType;
  final String? abhaId;
  final int? patientId;
  final String? roomId;
  final int? doctorId;
  final String? presLink;

  // Previous Observations / Vitals
  final double? spo2;
  final double? temperature;
  final String? bloodPressure;
  final double? height;
  final double? weight;
  final double? bmi;
  final String? chiefComplaints;
  final List<Map<String, dynamic>>? previousObservations;
  final Map<String, dynamic>? rawData;

  Appointment({
    this.id,
    this.patientName,
    this.patientPhone,
    this.patientEmail,
    this.appointmentDate,
    this.appointmentTime,
    this.status,
    this.reason,
    this.doctorName,
    this.villageName,
    this.subCenter,
    this.choName,
    this.choId,
    this.notes,
    this.createdAt,
    this.updatedAt,
    this.gender,
    this.age,
    this.address,
    this.tokenNumber,
    this.appointmentType,
    this.abhaId,
    this.patientId,
    this.roomId,
    this.doctorId,
    this.presLink,
    this.spo2,
    this.temperature,
    this.bloodPressure,
    this.height,
    this.weight,
    this.bmi,
    this.chiefComplaints,
    this.previousObservations,
    this.rawData,
  });

  factory Appointment.fromJson(Map<String, dynamic> json) {
    // Parse previous observations if available
    List<Map<String, dynamic>>? prevObs;
    if (json['previous_observations'] is List) {
      prevObs = (json['previous_observations'] as List)
          .whereType<Map<String, dynamic>>()
          .toList();
    } else if (json['observations'] is List) {
      prevObs = (json['observations'] as List)
          .whereType<Map<String, dynamic>>()
          .toList();
    }

    // Parse vitals from nested objects
    final vitals =
        json['vitals'] is Map ? json['vitals'] as Map<String, dynamic> : null;
    final patient =
        json['patient'] is Map ? json['patient'] as Map<String, dynamic> : null;
    final patientDetails = json['patient_details'] is Map
        ? json['patient_details'] as Map<String, dynamic>
        : json['patientDetails'] is Map
            ? json['patientDetails'] as Map<String, dynamic>
            : json['patient_data'] is Map
                ? json['patient_data'] as Map<String, dynamic>
                : json['patientData'] is Map
                    ? json['patientData'] as Map<String, dynamic>
                    : null;

    return Appointment(
      id: json['id'] ?? json['appointment_id'],
      patientName: json['patient_name'] ??
          json['patientName'] ??
          json['name'] ??
          patient?['name'] ??
          patient?['patient_name'] ??
          patientDetails?['name'] ??
          patientDetails?['patient_name'],
      patientPhone: json['patient_phone'] ??
          json['patientPhone'] ??
          json['phone'] ??
          patient?['phone'] ??
          patient?['mobile'] ??
          patientDetails?['phone'] ??
          patientDetails?['mobile'],
      patientEmail: json['patient_email'] ??
          json['patientEmail'] ??
          json['email'] ??
          patient?['email'] ??
          patientDetails?['email'],
      appointmentDate:
          json['appointment_date'] ?? json['appointmentDate'] ?? json['date'],
      appointmentTime:
          json['appointment_time'] ?? json['appointmentTime'] ?? json['time'],
      status: json['status'] ?? 'Pending',
      reason: json['reason'] ??
          json['visit_reason'] ??
          json['purpose'] ??
          json['chief_complaints'],
      doctorName: json['doctor_name'] ?? json['doctorName'],
      villageName:
          json['village_name'] ?? json['villageName'] ?? json['village'],
      subCenter: json['sub_center'] ?? json['subCenter'],
      choName: json['cho_name'] ?? json['choName'],
      choId: json['cho_id'] ?? json['choId'],
      notes: json['notes'] ?? json['remark'] ?? json['remarks'],
      createdAt: json['created_at'] ?? json['createdAt'],
      updatedAt: json['updated_at'] ?? json['updatedAt'],
      gender: json['gender'] ?? patient?['gender'] ?? patientDetails?['gender'],
      age: _parseInt(json['age'] ?? patient?['age'] ?? patientDetails?['age']),
      address:
          json['address'] ?? patient?['address'] ?? patientDetails?['address'],
      tokenNumber: json['token_number'] ?? json['tokenNumber'] ?? json['token'],
      appointmentType:
          json['appointment_type'] ?? json['appointmentType'] ?? json['type'],
      abhaId: json['abha_id'] ??
          json['abhaId'] ??
          json['ABHA_ID'] ??
          patient?['abha_id'] ??
          patientDetails?['abha_id'] ??
          patientDetails?['abhaId'],
      roomId: (json['room_id'] ?? json['roomId'])?.toString(),
      doctorId:
          _parseInt(json['doctor_id'] ?? json['doctorId'] ?? json['doctor']),
      presLink: (json['pres_link'] ?? json['presLink'] ?? json['pdf_url'] ?? json['pdfUrl'] ?? json['prescription_url'])?.toString(),
      patientId: _parseInt(
        json['patient_id'] ??
            json['patientId'] ??
            json['registration_patient_id'] ??
            json['beneficiary_id'] ??
            patient?['patient_id'] ??
            patient?['patientId'] ??
            patient?['id'] ??
            patientDetails?['patient_id'] ??
            patientDetails?['patientId'] ??
            patientDetails?['id'],
      ),
      spo2: _parseDouble(vitals?['spo2'] ?? json['spo2']),
      temperature: _parseDouble(vitals?['temperature'] ?? json['temperature']),
      bloodPressure: vitals?['blood_pressure']?.toString() ??
          json['blood_pressure']?.toString() ??
          json['bp']?.toString(),
      height: _parseDouble(vitals?['height'] ?? json['height']),
      weight: _parseDouble(vitals?['weight'] ?? json['weight']),
      bmi: _parseDouble(vitals?['bmi'] ?? json['bmi']),
      chiefComplaints: json['chief_complaints'] ??
          json['chiefComplaints'] ??
          vitals?['chief_complaints'],
      previousObservations: prevObs,
      rawData: json,
    );
  }

  static int? _parseInt(dynamic val) {
    if (val == null) return null;
    if (val is int) return val;
    return int.tryParse('$val');
  }

  static double? _parseDouble(dynamic val) {
    if (val == null) return null;
    if (val is double) return val;
    if (val is int) return val.toDouble();
    return double.tryParse('$val');
  }

  String get statusDisplay => (status ?? 'Pending').toUpperCase();

  bool get isPending =>
      status?.toLowerCase() == 'pending' ||
      status?.toLowerCase() == 'scheduled';

  bool get isCompleted =>
      status?.toLowerCase() == 'completed' || status?.toLowerCase() == 'done';

  bool get isCancelled =>
      status?.toLowerCase() == 'cancelled' ||
      status?.toLowerCase() == 'canceled';

  String get initials {
    final name = patientName ?? 'P';
    final parts = name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.substring(0, 1).toUpperCase();
  }
}

class LoginResponse {
  final bool success;
  final String? message;
  final String? token;
  final Map<String, dynamic>? userData;
  final int? choId;

  LoginResponse({
    required this.success,
    this.message,
    this.token,
    this.userData,
    this.choId,
  });

  factory LoginResponse.fromJson(Map<String, dynamic> json, int statusCode) {
    final data = json['data'];
    final nestedData = data is Map<String, dynamic> ? data : null;

    final cho = nestedData?['cho'] ?? json['cho'] ?? json['user'];
    final choMap = cho is Map<String, dynamic> ? cho : null;

    final isSuccess = json['success'] == true ||
        json['status'] == true ||
        json['status'] == 'success' ||
        (statusCode == 200 && json['success'] != false);

    final token = nestedData?['token'] ??
        nestedData?['access_token'] ??
        nestedData?['accessToken'] ??
        json['token'] ??
        json['access_token'];

    final choId = choMap?['cho_id'] ??
        choMap?['choId'] ??
        choMap?['id'] ??
        nestedData?['cho_id'] ??
        nestedData?['choId'] ??
        json['cho_id'];

    final userData = choMap ?? nestedData;
    final hasUsableSessionData =
        token != null || choId != null || userData != null;

    return LoginResponse(
      success: isSuccess && hasUsableSessionData,
      message: json['message'] ?? json['msg'] ?? json['error'],
      token: token?.toString(),
      userData: userData is Map<String, dynamic> ? userData : null,
      choId: choId is int ? choId : int.tryParse('${choId ?? ''}'),
    );
  }
}

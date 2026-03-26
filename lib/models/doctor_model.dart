class Doctor {
  final int id;
  final String name;
  final String? specialization;
  final String? email;
  final String? phone;
  final String? hprId;
  final String status; // 'online', 'busy', 'offline'
  final bool telemedicineAvailable;
  final String? profileImage;
  final String? qualification;
  final String? city;
  final String? gender;

  const Doctor({
    required this.id,
    required this.name,
    this.specialization,
    this.email,
    this.phone,
    this.hprId,
    this.status = 'offline',
    this.telemedicineAvailable = false,
    this.profileImage,
    this.qualification,
    this.city,
    this.gender,
  });

  factory Doctor.fromJson(Map<String, dynamic> json) {
    // Determine status from various possible field names
    final rawStatus = (json['status'] ?? json['indication'] ?? json['availability_status'] ?? json['is_online'] ?? '').toString().toLowerCase();
    String status;
    if (rawStatus == 'online' || rawStatus == 'available' || rawStatus == 'true' || rawStatus == '1') {
      status = 'online';
    } else if (rawStatus == 'busy' || rawStatus == 'in_consultation') {
      status = 'busy';
    } else {
      status = 'offline';
    }

    // Determine telemedicine availability
    final telemed = json['telemedicine_available'] ?? json['telemedicine'] ?? json['is_telemedicine'] ?? false;
    final telemedicineAvailable = telemed == true || telemed == 1 || telemed.toString().toLowerCase() == 'true' || telemed.toString().toLowerCase() == 'available';

    // Build name
    final firstName = (json['first_name'] ?? json['firstName'] ?? '').toString().trim();
    final lastName = (json['last_name'] ?? json['lastName'] ?? '').toString().trim();
    final fullName = (json['name'] ?? json['doctor_name'] ?? json['doctorName'] ?? '').toString().trim();
    final name = fullName.isNotEmpty
        ? fullName
        : '$firstName $lastName'.trim().isNotEmpty
            ? 'Dr. $firstName $lastName'.trim()
            : 'Dr. Unknown';

    return Doctor(
      id: int.tryParse('${json['id'] ?? json['doctor_id'] ?? 0}') ?? 0,
      name: name,
      specialization: (json['specialization'] ?? json['specialty'] ?? json['department'] ?? '').toString().trim().isEmpty
          ? null
          : (json['specialization'] ?? json['specialty'] ?? json['department']).toString().trim(),
      email: (json['email'] ?? '').toString().trim().isEmpty ? null : json['email'].toString().trim(),
      phone: (json['phone'] ?? json['mobile'] ?? json['contact'] ?? '').toString().trim().isEmpty
          ? null
          : (json['phone'] ?? json['mobile'] ?? json['contact']).toString().trim(),
      hprId: (json['hpr_id'] ?? json['hprId'] ?? json['HPR_ID'] ?? '').toString().trim().isEmpty
          ? null
          : (json['hpr_id'] ?? json['hprId'] ?? json['HPR_ID']).toString().trim(),
      status: status,
      telemedicineAvailable: telemedicineAvailable,
      profileImage: (json['profile_image'] ?? json['avatar'] ?? json['photo'] ?? '').toString().trim().isEmpty
          ? null
          : (json['profile_image'] ?? json['avatar'] ?? json['photo']).toString().trim(),
      qualification: (json['qualification'] ?? json['degree'] ?? '').toString().trim().isEmpty
          ? null
          : (json['qualification'] ?? json['degree']).toString().trim(),
      city: (json['city'] ?? json['location'] ?? '').toString().trim().isEmpty
          ? null
          : (json['city'] ?? json['location']).toString().trim(),
      gender: (json['gender'] ?? '').toString().trim().isEmpty
          ? null
          : (json['gender']).toString().trim(),
    );
  }

  String get initials {
    final parts = name.replaceAll('Dr.', '').replaceAll('dr.', '').trim().split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '${parts[0][0]}${parts.last[0]}'.toUpperCase();
  }

  bool get isOnline => status == 'online';
  bool get isBusy => status == 'busy';
  bool get isOffline => status == 'offline';
}

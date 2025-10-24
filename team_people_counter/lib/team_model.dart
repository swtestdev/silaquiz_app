class Team {
  String name;
  String qrCode;
  int count;

  Team({required this.name, required this.qrCode, this.count = 0});

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'qrCode': qrCode,
      'count': count,
    };
  }

  factory Team.fromJson(Map<String, dynamic> json) {
    return Team(
      name: json['name'] ?? '',
      qrCode: json['qrCode'] ?? '',
      count: json['count'] ?? 0,
    );
  }
} 
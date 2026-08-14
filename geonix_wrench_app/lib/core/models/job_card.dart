class PartUsed {
  PartUsed({required this.partName, required this.quantity, this.unitPrice});

  final String partName;
  final int quantity;
  final double? unitPrice;

  factory PartUsed.fromJson(Map<String, dynamic> json) {
    return PartUsed(
      partName: (json['part_name'] ?? '').toString(),
      quantity: _toInt(json['quantity']) ?? 0,
      unitPrice: _toDouble(json['unit_price']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'part_name': partName,
      'quantity': quantity,
      if (unitPrice != null) 'unit_price': unitPrice,
    };
  }
}

class JobCard {
  JobCard({
    required this.id,
    required this.vehicleInfo,
    required this.laborHours,
    this.laborRate,
    required this.workPerformed,
    required this.partsUsed,
    required this.unbilledItemsFlagged,
    required this.transcript,
  });

  final int id;
  final String vehicleInfo;
  final double laborHours;
  final double? laborRate;
  final String workPerformed;
  final List<PartUsed> partsUsed;
  final List<String> unbilledItemsFlagged;
  final String transcript;

  factory JobCard.fromJson(Map<String, dynamic> json) {
    final extraction = (json['extraction'] as Map).cast<String, dynamic>();

    final rawParts = extraction['parts_used'];
    final parts = rawParts is List
        ? rawParts
            .whereType<Map>()
            .map((part) => PartUsed.fromJson(part.cast<String, dynamic>()))
            .toList()
        : <PartUsed>[];

    final rawFlagged = extraction['unbilled_items_flagged'];
    final flagged = rawFlagged is List
        ? rawFlagged.map((item) => item.toString()).toList()
        : <String>[];

    return JobCard(
      id: json['jobcard_id'] as int,
      vehicleInfo: (extraction['vehicle_info'] ?? '').toString(),
      laborHours: _toDouble(extraction['labor_hours']) ?? 0,
      laborRate: _toDouble(extraction['labor_rate']),
      workPerformed: (extraction['work_performed'] ?? '').toString(),
      partsUsed: parts,
      unbilledItemsFlagged: flagged,
      transcript: (json['transcript'] ?? '').toString(),
    );
  }
}

double? _toDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

int? _toInt(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
}

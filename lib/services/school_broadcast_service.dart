import 'package:cloud_functions/cloud_functions.dart';

import 'school_service.dart' show SchoolException;

class BroadcastRecipient {
  final String name;
  final String phone;
  const BroadcastRecipient({required this.name, required this.phone});
}

class BroadcastResult {
  final int emailsSent;
  final int emailsFailed;
  final int smsAttempted;
  final List<BroadcastRecipient> whatsappRecipients;
  const BroadcastResult({
    required this.emailsSent,
    required this.emailsFailed,
    required this.smsAttempted,
    required this.whatsappRecipients,
  });
}

/// School Network, Stage 9 (added 2026-09-13, per explicit user
/// confirmation) — client side of `broadcastToGuardians`. Email really
/// sends; SMS is still the Stage 6 stub; WhatsApp has never had a
/// Business API in this app, so [BroadcastResult.whatsappRecipients] is
/// handed back for the caller to build the same manual wa.me tap-through
/// every other WhatsApp send in this app already uses (see
/// BroadcastScreen).
class SchoolBroadcastService {
  SchoolBroadcastService({FirebaseFunctions? functions}) : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<BroadcastResult> broadcast({
    required String schoolId,
    List<String>? classIds,
    required String subject,
    required String message,
  }) async {
    try {
      final callable = _functions.httpsCallable('broadcastToGuardians', options: HttpsCallableOptions(timeout: const Duration(seconds: 170)));
      final result = await callable.call<Map<String, dynamic>>({
        'schoolId': schoolId,
        if (classIds != null) 'classIds': classIds,
        'subject': subject,
        'message': message,
      });
      final data = result.data;
      final whatsapp = (data['whatsappRecipients'] as List? ?? [])
          .map((r) => BroadcastRecipient(name: r['name'] as String? ?? '', phone: r['phone'] as String? ?? ''))
          .toList();
      return BroadcastResult(
        emailsSent: (data['emailsSent'] as num?)?.toInt() ?? 0,
        emailsFailed: (data['emailsFailed'] as num?)?.toInt() ?? 0,
        smsAttempted: (data['smsAttempted'] as num?)?.toInt() ?? 0,
        whatsappRecipients: whatsapp,
      );
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not send the broadcast.');
    }
  }
}

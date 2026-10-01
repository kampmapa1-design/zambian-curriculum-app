import 'dart:async';

import 'package:flutter/material.dart';

import '../services/cloud_backup_scheduler.dart';

/// The home screen's silent trigger for [CloudBackupScheduler]'s
/// opportunistic automatic cloud backup — same "a StatefulWidget purely
/// for its side effect, dropped into an otherwise-StatelessWidget screen"
/// pattern as [CdcNewMaterialsBanner], but this one renders nothing at
/// all, ever ([SizedBox.shrink]): an automatic backup succeeding or
/// failing is not something a teacher needs a banner for on every single
/// app open (see [CloudBackupScheduler.maybeBackUpInBackground]'s own doc
/// comment on why failures are silent) — the Data Backup screen is where
/// a teacher checks backup status on purpose, not the home screen.
class CloudBackupTrigger extends StatefulWidget {
  const CloudBackupTrigger({super.key, this.scheduler});

  final CloudBackupScheduler? scheduler;

  @override
  State<CloudBackupTrigger> createState() => _CloudBackupTriggerState();
}

class _CloudBackupTriggerState extends State<CloudBackupTrigger> {
  @override
  void initState() {
    super.initState();
    unawaited((widget.scheduler ?? CloudBackupScheduler()).maybeBackUpInBackground());
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

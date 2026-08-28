import 'dart:async';

import 'package:flutter/material.dart';

/// One selectable option in [showTimedChoiceDialog].
class TimedChoiceOption<T> {
  final T value;
  final String label;
  final IconData? icon;

  const TimedChoiceOption({required this.value, required this.label, this.icon});
}

/// A pop-up choice that resolves itself to [defaultValue] after
/// [timeout] (5 seconds, per the AI Marking spec) if the user hasn't
/// answered — with a visible countdown, so auto-resolving never looks
/// like a silent/confusing dismissal. Used wherever this app needs to ask
/// a quick formatting/processing question without blocking a teacher who
/// has stepped away mid-task.
///
/// Set [showCancel] to offer an explicit "Cancel" alongside the timed
/// options — returns `null` in that case (a timeout NEVER returns null,
/// only [defaultValue] or an explicitly-picked option), so a caller can
/// tell "timed out, use the default" apart from "the user asked to stop"
/// and act accordingly — e.g. abort instead of silently proceeding with a
/// default the user didn't actually want.
///
/// [defaultValue] must be one of [options]' values — asserted, not just
/// assumed, since a default that isn't actually offered would be a real
/// bug here, not a formatting nitpick.
Future<T?> showTimedChoiceDialog<T>({
  required BuildContext context,
  required String title,
  String? message,
  required List<TimedChoiceOption<T>> options,
  required T defaultValue,
  Duration timeout = const Duration(seconds: 5),
  bool showCancel = false,
}) async {
  assert(
    options.any((o) => o.value == defaultValue),
    'defaultValue must match one of the provided options',
  );

  return showDialog<T>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _TimedChoiceDialogContent<T>(
      title: title,
      message: message,
      options: options,
      defaultValue: defaultValue,
      timeout: timeout,
      showCancel: showCancel,
    ),
  );
}

class _TimedChoiceDialogContent<T> extends StatefulWidget {
  const _TimedChoiceDialogContent({
    required this.title,
    required this.message,
    required this.options,
    required this.defaultValue,
    required this.timeout,
    required this.showCancel,
  });

  final String title;
  final String? message;
  final List<TimedChoiceOption<T>> options;
  final T defaultValue;
  final Duration timeout;
  final bool showCancel;

  @override
  State<_TimedChoiceDialogContent<T>> createState() => _TimedChoiceDialogContentState<T>();
}

class _TimedChoiceDialogContentState<T> extends State<_TimedChoiceDialogContent<T>> {
  late int _secondsLeft = widget.timeout.inSeconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) {
        _timer?.cancel();
        Navigator.of(context).pop(widget.defaultValue);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _choose(T value) {
    _timer?.cancel();
    Navigator.of(context).pop(value);
  }

  void _cancel() {
    _timer?.cancel();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final defaultOption = widget.options.firstWhere((o) => o.value == widget.defaultValue);
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.message != null) ...[
            Text(widget.message!),
            const SizedBox(height: 12),
          ],
          for (final option in widget.options)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: OutlinedButton.icon(
                onPressed: () => _choose(option.value),
                icon: Icon(option.icon ?? Icons.circle_outlined, size: 18),
                label: Align(alignment: Alignment.centerLeft, child: Text(option.label)),
              ),
            ),
          const SizedBox(height: 4),
          Text(
            'Defaulting to "${defaultOption.label}" in $_secondsLeft s if nothing is chosen…',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
        ],
      ),
      actions: widget.showCancel
          ? [TextButton(onPressed: _cancel, child: const Text('Cancel'))]
          : null,
    );
  }
}

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../widgets/gradient_app_bar.dart';

/// Owner-only finance view (Monetization Stages 5, 7 and 8): rolling 12-month
/// revenue against the VAT threshold, measured-vs-modelled AI cost per page
/// for each marking engine, the live credit/bundle configuration, and the
/// editable USD→kwacha exchange rate.
///
/// Access is enforced SERVER-side: `getOwnerFinanceSummary` and
/// `updateExchangeRate` refuse anyone whose uid isn't listed in the
/// owner-only `ownerData/settings` document. Hiding this screen from other
/// users is only a courtesy — it is not the protection.
///
/// (There is no separate web dashboard — the existing web dashboard is the
/// teacher submissions mailbox and has no admin/owner layer — so this lives
/// in the app, reached from the Marking Credits screen for the owner only.)
class OwnerFinanceScreen extends StatefulWidget {
  const OwnerFinanceScreen({super.key, this.fetchSummary, this.saveRate, this.embedded = false});

  /// True when shown inside the web dashboard's own layout (no app bar of its own).
  final bool embedded;

  /// Injectable for tests. Defaults call the Cloud Functions.
  final Future<Map<String, Object?>> Function()? fetchSummary;
  final Future<void> Function(double rate)? saveRate;

  @override
  State<OwnerFinanceScreen> createState() => _OwnerFinanceScreenState();
}

class _OwnerFinanceScreenState extends State<OwnerFinanceScreen> {
  Map<String, Object?>? _data;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, Object?>> _defaultFetch() async {
    final result = await FirebaseFunctions.instance.httpsCallable('getOwnerFinanceSummary').call<Object?>();
    final data = result.data;
    if (data is! Map) throw StateError('Unexpected reply from the server.');
    return Map<String, Object?>.from(data);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await (widget.fetchSummary ?? _defaultFetch)();
      if (mounted) setState(() => _data = data);
    } on FirebaseFunctionsException catch (e) {
      if (mounted) setState(() => _error = e.message ?? 'Could not load the finance summary.');
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load the finance summary: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _editRate(double current) async {
    final rate = await showDialog<double>(context: context, builder: (_) => _ExchangeRateDialog(current: current));
    if (rate == null || !mounted) return;
    try {
      if (widget.saveRate != null) {
        await widget.saveRate!(rate);
      } else {
        await FirebaseFunctions.instance.httpsCallable('updateExchangeRate').call<Object?>({'rate': rate});
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Exchange rate updated.')));
      await _load();
    } on FirebaseFunctionsException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message ?? 'Could not save the rate.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save the rate: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embedded ? null : const GradientAppBar(title: 'Owner finance'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _load, child: const Text('Try again')),
                    ]),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  // Centred and width-limited so the cards stay readable on a wide desktop browser.
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 900),
                      child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                    children: [
                      if (widget.embedded)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(children: [
                            Expanded(child: Text('Owner finance', style: Theme.of(context).textTheme.headlineSmall)),
                            IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh_outlined), onPressed: _load),
                          ]),
                        ),
                      _revenueCard(context, _map(_data?['revenue'])),
                      const SizedBox(height: 12),
                      _fxCard(context, _map(_data?['fx'])),
                      const SizedBox(height: 12),
                      _costCard(context, _map(_data?['usage'])),
                      const SizedBox(height: 12),
                      _featuresCard(context, _map(_data?['features']), _num(_data?['targetCostPerCreditUsd'])),
                      const SizedBox(height: 12),
                      _configCard(context, _map(_data?['config'])),
                    ],
                  ),
                    ),
                  ),
                ),
    );
  }

  static Map<String, Object?> _map(Object? v) => v is Map ? Map<String, Object?>.from(v) : <String, Object?>{};
  static double _num(Object? v) => v is num ? v.toDouble() : 0;
  static String _k(num n) {
    final s = n.round().toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return 'K$b';
  }

  static String _w(double c) => c == c.roundToDouble() ? c.toStringAsFixed(0) : c.toString();

  Widget _revenueCard(BuildContext context, Map<String, Object?> r) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final rolling = _num(r['rolling12mKwacha']);
    final threshold = _num(r['thresholdKwacha']);
    final pct = (_num(r['percentOfThreshold']) / 100).clamp(0.0, 1.0);
    final crossed = r['vatThresholdCrossed'] == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Revenue — rolling 12 months', style: t.titleMedium),
            const SizedBox(height: 8),
            Text(_k(rolling), key: const Key('rolling-revenue'), style: t.headlineMedium),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: pct, minHeight: 8, borderRadius: BorderRadius.circular(4)),
            const SizedBox(height: 6),
            Text(
              crossed
                  ? 'VAT threshold of ${_k(threshold)} has been reached.'
                  : '${_k(_num(r['remainingKwacha']))} to go until the ${_k(threshold)} VAT threshold '
                      '(${_num(r['percentOfThreshold']).toStringAsFixed(1)}%).',
              key: const Key('threshold-line'),
              style: t.bodyMedium?.copyWith(color: crossed ? cs.error : null, fontWeight: crossed ? FontWeight.bold : null),
            ),
            const SizedBox(height: 6),
            Text(
              '${r['basis'] ?? ''} The threshold figure is unverified — confirm it with your accountant.',
              style: t.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _fxCard(BuildContext context, Map<String, Object?> fx) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final rate = _num(fx['rate']);
    final days = fx['daysSinceUpdate'];
    final stale = fx['stale'] == true;
    return Card(
      color: stale ? cs.errorContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text('Exchange rate', style: t.titleMedium)),
              TextButton(onPressed: () => _editRate(rate), child: const Text('Update')),
            ]),
            Text('K${_w(rate)} per US\$1', key: const Key('fx-rate'), style: t.headlineSmall),
            const SizedBox(height: 4),
            Text(
              days == null ? 'Never updated — this is the default. Please set the real rate.' : 'Last updated $days day${days == 1 ? '' : 's'} ago.',
              key: const Key('fx-age'),
            ),
            if (stale)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  days == null ? 'Set the rate so revenue in dollars converts correctly.' : 'Out of date (over 60 days) — update it.',
                  key: const Key('fx-stale'),
                  style: t.bodyMedium?.copyWith(color: cs.onErrorContainer, fontWeight: FontWeight.bold),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _costCard(BuildContext context, Map<String, Object?> usage) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    const engines = [('stable', 'Stable Marker'), ('concise', 'Concise Marking'), ('keyed', 'Key-based Marking')];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('AI cost per marked page (USD)', style: t.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Measured includes retries that cost money but produced no page. Modelled is the estimate the pricing was built on.',
              style: t.bodySmall,
            ),
            const SizedBox(height: 8),
            for (final (key, label) in engines)
              Builder(builder: (context) {
                final u = _map(usage[key]);
                final measured = u['measuredCostPerPageUsd'];
                final modeled = _num(u['modeledCostPerPageUsd']);
                final ratio = u['measuredVsModeled'];
                final over = ratio is num && ratio > 1.25;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(label, style: t.titleSmall),
                    Text(
                      measured is num
                          ? 'Measured \$${measured.toStringAsFixed(4)}  vs  modelled \$${modeled.toStringAsFixed(4)}'
                              '  (${(ratio as num).toStringAsFixed(2)}×)'
                          : 'No marking data yet  ·  modelled \$${modeled.toStringAsFixed(4)}',
                      key: Key('cost-line-$key'),
                      style: t.bodyMedium?.copyWith(color: over ? cs.error : null),
                    ),
                    Text(
                      '${_num(u['successes']).round()} of ${_num(u['attempts']).round()} attempts produced a result · '
                      '${_num(u['pagesSuccessful']).round()} pages',
                      style: t.bodySmall,
                    ),
                    if (over) Text('Running over the model — worth a look at pricing.', style: t.bodySmall?.copyWith(color: cs.error)),
                    if (_num(u['unpricedAttempts']) > 0)
                      Text('${_num(u['unpricedAttempts']).round()} attempts used a model with no price on file (not costed).', style: t.bodySmall),
                  ]),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _featuresCard(BuildContext context, Map<String, Object?> features, double targetPerCredit) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final names = features.keys.toList()..sort();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Other AI features — cost per use', style: t.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Real AI cost per successful use, against the credits charged. One credit is meant to be worth about '
              '\$${targetPerCredit.toStringAsFixed(4)} of AI cost; a feature well above that is under-priced. '
              'The credit amounts are starting estimates until real usage arrives.',
              style: t.bodySmall,
            ),
            const SizedBox(height: 8),
            for (final name in names)
              Builder(builder: (context) {
                final f = _map(features[name]);
                final credits = f['creditsPerUse'];
                final measured = f['measuredCostPerUseUsd'];
                final implied = f['impliedCostPerCreditUsd'];
                final under = implied is num && targetPerCredit > 0 && implied > targetPerCredit * 1.25;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name, style: t.titleSmall),
                    Text(
                      measured is num
                          ? '\$${measured.toStringAsFixed(4)} per use  ·  ${credits is num ? _w(credits.toDouble()) : '?'} credits'
                              '${implied is num ? '  ·  \$${implied.toStringAsFixed(4)}/credit' : ''}'
                          : 'No usage yet  ·  ${credits is num ? _w(credits.toDouble()) : '?'} credits',
                      key: Key('feature-line-$name'),
                      style: t.bodyMedium?.copyWith(color: under ? cs.error : null),
                    ),
                    Text('${_num(f['successes']).round()} successful of ${_num(f['requests']).round()} requests', style: t.bodySmall),
                    if (under) Text('Costs more than it charges — consider raising its credits.', style: t.bodySmall?.copyWith(color: cs.error)),
                  ]),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _configCard(BuildContext context, Map<String, Object?> c) {
    final t = Theme.of(context).textTheme;
    final active = _map(c['activeWeights']);
    final next = c['nextWeights'] == null ? null : _map(c['nextWeights']);
    final bundles = _map(c['bundles']);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Live configuration', style: t.titleMedium),
            const SizedBox(height: 8),
            Text('Credits mode: ${c['mode']}', key: const Key('config-mode')),
            Text('Other AI features mode: ${c['featuresMode'] ?? 'off'}', key: const Key('config-features-mode')),
            Text('Ad passes: ${_map(c['adPasses'])['enabled'] == true ? 'on' : 'off'}', key: const Key('config-ad-passes')),
            Text('Free credits each month: ${_w(_num(c['freeMonthlyCredits']))}'),
            const SizedBox(height: 6),
            Text('Credits per page now: Stable ${_w(_num(active['stable']))}, Concise ${_w(_num(active['concise']))}, Key-based ${_w(_num(active['keyed']))}'),
            if (next != null)
              Text(
                'Next (from ${next['effectiveFrom']}): Stable ${_w(_num(next['stable']))}, Concise ${_w(_num(next['concise']))}, Key-based ${_w(_num(next['keyed']))}',
                style: t.bodySmall,
              ),
            const SizedBox(height: 6),
            Text('Bundle scenario: ${c['activeScenario']}'),
            for (final e in bundles.entries)
              Builder(builder: (context) {
                final b = _map(e.value);
                final price = _map(b['listPrice']);
                return Text('  ${e.key}: ${_w(_num(b['credits']))} credits @ ${price['currency']} ${_w(_num(price['amount']))}', style: t.bodySmall);
              }),
          ],
        ),
      ),
    );
  }
}

/// Owns its own [TextEditingController] so it is disposed only when the dialog
/// is truly gone — disposing it right after `showDialog` returns would rebuild
/// the text field with a dead controller during the dialog's closing animation.
class _ExchangeRateDialog extends StatefulWidget {
  const _ExchangeRateDialog({required this.current});

  final double current;

  @override
  State<_ExchangeRateDialog> createState() => _ExchangeRateDialogState();
}

class _ExchangeRateDialogState extends State<_ExchangeRateDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.current.toString());

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Exchange rate'),
      // A definite width: without it the dialog's intrinsic-width pass sizes the
      // TextField to almost nothing and the explanatory text wraps letter by letter.
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Kwacha per 1 US dollar. Used to convert any dollar-priced bundle into kwacha for the revenue total.'),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'K per \$1', border: OutlineInputBorder()),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final v = double.tryParse(_controller.text.trim());
            if (v == null || v < 1 || v > 1000) return; // the server validates too
            Navigator.of(context).pop(v);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

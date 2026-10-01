import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../models/marking_credits.dart';
import '../services/marking_credits_service.dart';
import '../services/marking_purchase_service.dart';
import '../services/rewarded_ad_service.dart';
import '../services/teacher_auth_service.dart';
import '../widgets/app_glass_surface.dart';
import '../widgets/gradient_app_bar.dart';
import 'login_screen.dart';

String _fmt(double c) => c == c.roundToDouble() ? c.toStringAsFixed(0) : c.toStringAsFixed(1);

/// Marking credits: the teacher's balance, what each engine costs per page,
/// the bundles they can buy, and their recent credit activity.
///
/// Everything shown is READ from the server-authoritative ledger; buying goes
/// through Google Play and is only credited once the server has verified the
/// purchase (see [PurchaseProcessor]). Bundles are shown for sale only when
/// credits are switched to "enforced" in the remote config — while it is off
/// (today's behaviour) or in trial ("shadow"), marking is free and nothing is
/// for sale.
class MarkingCreditsScreen extends StatefulWidget {
  const MarkingCreditsScreen({
    super.key,
    this.creditsService,
    this.purchaseService,
    this.isAnonymous,
    this.now,
    this.openLogin,
  });

  // Injectable so widget tests never need Firebase or Google Play.
  final MarkingCreditsService? creditsService;
  final MarkingPurchaseService? purchaseService;
  final bool Function()? isAnonymous;
  final DateTime Function()? now;
  final Future<bool?> Function(BuildContext context)? openLogin;

  @override
  State<MarkingCreditsScreen> createState() => _MarkingCreditsScreenState();
}

class _MarkingCreditsScreenState extends State<MarkingCreditsScreen> {
  late final MarkingCreditsService _credits = widget.creditsService ?? MarkingCreditsService.instance;
  late final MarkingPurchaseService _purchases = widget.purchaseService ?? MarkingPurchaseService.instance;
  DateTime _now() => (widget.now ?? DateTime.now)();
  bool _isAnonymous() => (widget.isAnonymous ?? () => TeacherAuthService().isAnonymous)();

  MarkingCreditsConfig? _config;
  CreditBalance? _balance;
  List<CreditTransaction> _history = const [];
  Map<String, ProductDetails> _products = const {};
  bool _storeReady = false;
  bool _loading = true;
  bool _buying = false;
  String? _accountId;
  String? _loadError;

  StreamSubscription<CreditBalance>? _balanceSub;
  StreamSubscription<PurchaseOutcome>? _outcomeSub;

  @override
  void initState() {
    super.initState();
    _outcomeSub = _purchases.outcomes.listen(_onPurchaseOutcome);
    unawaited(_load());
  }

  @override
  void dispose() {
    _balanceSub?.cancel();
    _outcomeSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _buying = false); // also un-sticks the buttons if a purchase dialog never reported back
    try {
      final config = await _credits.loadConfig();
      final uid = await _credits.currentUid();
      if (!mounted) return;
      setState(() {
        _config = config;
        _accountId = uid;
      });

      _balanceSub?.cancel();
      _balanceSub = _credits.watchBalance().listen(
        (b) {
          if (mounted) setState(() => _balance = b);
        },
        onError: (_) {},
      );

      unawaited(_loadHistory());
      if (config.isEnforced) await _loadStore(config);
    } catch (e) {
      if (mounted) setState(() => _loadError = 'Could not load your credits. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadHistory() async {
    try {
      final h = await _credits.recentTransactions();
      if (mounted) setState(() => _history = h);
    } catch (_) {
      // History is a nicety; the balance above is what matters.
    }
  }

  Future<void> _loadStore(MarkingCreditsConfig config) async {
    final ids = {for (final b in config.activeBundles) b.productId};
    final ready = await _purchases.isAvailable;
    final products = ready ? await _purchases.loadProducts(ids) : const <ProductDetails>[];
    if (!mounted) return;
    setState(() {
      _storeReady = ready && products.isNotEmpty;
      _products = {for (final p in products) p.id: p};
    });
    // Pick up anything paid for but never credited (e.g. no signal at the time).
    if (ready && !_isAnonymous()) unawaited(_purchases.recoverPending());
  }

  void _onPurchaseOutcome(PurchaseOutcome o) {
    if (!mounted) return;
    setState(() => _buying = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(o.message), duration: const Duration(seconds: 6)));
    if (o.kind == PurchaseOutcomeKind.credited || o.kind == PurchaseOutcomeKind.alreadyCredited) unawaited(_loadHistory());
    if (o.kind == PurchaseOutcomeKind.needsSignIn) unawaited(_openLogin());
  }

  Future<void> _openLogin() async {
    final signedIn = widget.openLogin != null
        ? await widget.openLogin!(context)
        : await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const LoginScreen()));
    if (!mounted) return;
    setState(() {}); // re-evaluate anonymous state
    if (signedIn == true) unawaited(_purchases.recoverPending());
  }

  Future<void> _buy(ProductDetails product) async {
    if (_isAnonymous()) {
      await _openLogin();
      return;
    }
    setState(() => _buying = true);
    try {
      final launched = await _purchases.buy(product);
      if (!launched && mounted) {
        setState(() => _buying = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open Google Play. Please try again.')));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _buying = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not start the purchase: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const GradientAppBar(title: 'Marking Credits'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  if (_loadError != null) _notice(context, _loadError!, error: true),
                  if (_config != null) ...[
                    _buildBalanceCard(context, _config!),
                    const SizedBox(height: 12),
                    _buildCostsCard(context, _config!),
                    const SizedBox(height: 12),
                    _buildBuySection(context, _config!),
                    if (_history.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _buildHistoryCard(context),
                    ],
                    const SizedBox(height: 12),
                    _buildFooter(context),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _notice(BuildContext context, String text, {bool error = false}) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: error ? cs.errorContainer : cs.secondaryContainer,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(padding: const EdgeInsets.all(12), child: Text(text)),
    );
  }

  Widget _buildBalanceCard(BuildContext context, MarkingCreditsConfig config) {
    final t = Theme.of(context).textTheme;
    final balance = _balance ?? CreditBalance.empty;
    final now = _now();
    final free = balance.freeAvailable(config, now);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your marking credits', style: t.titleMedium),
            const SizedBox(height: 8),
            if (config.isEnforced) ...[
              Text('${_fmt(balance.spendable(config, now))} credits', key: const Key('spendable-credits'), style: t.headlineMedium),
              const SizedBox(height: 8),
              Text('Free this month: ${_fmt(free)} — these reset on the 1st of each month and do not carry over.', style: t.bodySmall),
              const SizedBox(height: 2),
              Text('Bought: ${_fmt(balance.purchasedCredits)} — these never expire.', style: t.bodySmall),
              const SizedBox(height: 2),
              Text('Free credits are used first.', style: t.bodySmall),
            ] else
              Text(
                config.mode == 'shadow'
                    ? "Credits are being trialled: marking is still free, and nothing is taken from you."
                    : 'Credits are not switched on yet — marking is currently free.',
                key: const Key('credits-off-note'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCostsCard(BuildContext context, MarkingCreditsConfig config) {
    final t = Theme.of(context).textTheme;
    final now = _now();
    final current = config.weightSetAt(now).weights;
    final upcoming = config.upcomingWeightSet(now);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('What marking costs (per page)', style: t.titleMedium),
            const SizedBox(height: 8),
            for (final e in MarkingEngineKind.values)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [Text(e.label), Text('${_fmt(current.of(e))} credits', key: Key('cost-${e.name}'))],
                ),
              ),
            if (upcoming != null) ...[
              const SizedBox(height: 10),
              Text(
                'From ${_dateLabel(upcoming.effectiveFrom)}: '
                '${MarkingEngineKind.values.map((e) => '${e.label} ${_fmt(upcoming.weights.of(e))}').join(', ')}.',
                key: const Key('upcoming-prices'),
                style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.tertiary),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // Zambia time, matching the config's own "+02:00" dates.
  String _dateLabel(DateTime utc) {
    final d = utc.add(const Duration(hours: 2));
    const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  Widget _buildBuySection(BuildContext context, MarkingCreditsConfig config) {
    final t = Theme.of(context).textTheme;
    if (!config.isEnforced) return const SizedBox.shrink();
    final now = _now();
    final weights = config.weightSetAt(now).weights;
    final bundles = config.activeBundles;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Buy credits', style: t.titleMedium),
            const SizedBox(height: 4),
            Text('Paid through Google Play. Credits are added once Google confirms the payment.', style: t.bodySmall),
            const SizedBox(height: 8),
            if (_isAnonymous())
              _notice(context, 'Sign in with your phone number or email before buying, so your credits are safe if you reinstall or change phone.')
            else if (!_storeReady)
              _notice(context, "Purchases aren't available right now. Make sure you installed the app from Google Play and are online, then pull down to refresh."),
            for (final b in bundles)
              ListTile(
                key: Key('bundle-${b.productId}'),
                contentPadding: EdgeInsets.zero,
                title: Text('${_fmt(b.credits)} credits'),
                subtitle: Text(
                  '≈ ${(b.credits / weights.stable).floor()} pages Stable · '
                  '${(b.credits / weights.concise).floor()} pages Concise · '
                  '${(b.credits / weights.keyed).floor()} pages Key-based',
                ),
                trailing: FilledButton(
                  onPressed: _buying || (_storeReady && _products[b.productId] == null)
                      ? null
                      : () {
                          final p = _products[b.productId];
                          if (_isAnonymous()) {
                            unawaited(_openLogin());
                          } else if (p != null) {
                            unawaited(_buy(p));
                          }
                        },
                  child: Text(_products[b.productId]?.price ?? '${b.currency == 'ZMW' ? 'K' : '${b.currency} '}${_fmt(b.listAmount)}'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryCard(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Recent activity', style: t.titleMedium),
            const SizedBox(height: 8),
            for (final h in _history.take(15))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Expanded(child: Text(h.description, style: t.bodyMedium)),
                    Text(
                      '${h.credits > 0 ? '+' : ''}${_fmt(h.credits)}',
                      style: t.bodyMedium?.copyWith(color: h.credits > 0 ? Colors.green.shade700 : null),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_accountId != null)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('Account ID (tap to copy)', style: t.bodySmall),
            subtitle: Text(_accountId!, key: const Key('account-id'), style: t.bodySmall),
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: _accountId!));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Account ID copied')));
            },
          ),
      ],
    );
  }
}

/// Shown when a marking call was refused (or pre-empted) for lack of credits.
/// Offers to go straight to the credits screen. Nothing was charged.
Future<void> showOutOfCreditsDialog(BuildContext context, InsufficientCreditsException? reason) {
  final feature = reason?.feature;
  final detail = reason == null
      ? "You don't have enough marking credits for the next script."
      : feature == null
          ? 'The next script needs ${_fmt(reason.requiredCredits)} credits and you have ${_fmt(reason.availableCredits)}.'
          : 'Making this ${featureLabel(feature)} needs ${_fmt(reason.requiredCredits)} credits and you have ${_fmt(reason.availableCredits)}.';
  final consequence = feature == null
      ? 'Anything already marked is kept, and the rest stays queued — nothing was charged for it.'
      : 'Nothing was charged, and anything you already made is kept.';
  final offerAd = reason?.adPassEligible == true && AdPassEarner.instance.supportsAdPasses;
  // Stage J (glassmorphism overlays, 2026-09-27): this is THE app-wide
  // "ad-gate" dialog — shown from `main.dart` whenever any metered AI
  // feature is refused for lack of credits — so it's the flagship real
  // example named in that stage's own spec.
  return showAppGlassAlertDialog<void>(
    context,
    title: feature == null ? 'Out of marking credits' : 'Out of credits',
    content: Text('$detail\n\n$consequence'),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Not now')),
      if (offerAd)
        TextButton(
          onPressed: () async {
            Navigator.of(context).pop();
            final uid = await MarkingCreditsService.instance.currentUid();
            final result = await AdPassEarner.instance.showForPass(uid: uid);
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(result == AdPassResult.earned
                  ? 'Thanks! Your ad pass is being added — try again in a few seconds.'
                  : 'No ad pass was earned.'),
            ));
          },
          child: const Text('Watch an ad instead'),
        ),
      FilledButton(
        onPressed: () {
          Navigator.of(context).pop();
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MarkingCreditsScreen()));
        },
        child: const Text('Get credits'),
      ),
    ],
  );
}

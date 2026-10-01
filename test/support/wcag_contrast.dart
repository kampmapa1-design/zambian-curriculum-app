// Standard WCAG 2.x relative-luminance / contrast-ratio formulas — used by
// this app's own accessibility checks (Stage O of the aesthetics pass) so
// a gradient/shadow/color choice's real contrast is measured, not assumed.
import 'dart:math' as math;

import 'package:flutter/material.dart';

double _linearize(double channel) => channel <= 0.03928 ? channel / 12.92 : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();

/// WCAG relative luminance of [color], 0 (black) to 1 (white).
double relativeLuminance(Color color) {
  final r = _linearize(color.r);
  final g = _linearize(color.g);
  final b = _linearize(color.b);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/// WCAG contrast ratio between [a] and [b], 1 (identical) to 21 (black/white).
double contrastRatio(Color a, Color b) {
  final l1 = relativeLuminance(a);
  final l2 = relativeLuminance(b);
  final lighter = math.max(l1, l2);
  final darker = math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}

/// WCAG AA minimums.
const kWcagAaNormalText = 4.5;
const kWcagAaLargeText = 3.0;

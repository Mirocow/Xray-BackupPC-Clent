/// Общие цвета и виджеты в стиле веб-панели (тёмная ops-тема).
library;

import 'package:flutter/material.dart';

const kBg = Color(0xFF0B1220);
const kCard = Color(0xFF121A2A);
const kInk = Color(0xFFE6EDF3);
const kDim = Color(0xFF8B98A9);
const kUp = Color(0xFF3FB950);
const kDown = Color(0xFF58A6FF);
const kWarn = Color(0xFFD29922);
const kAccent = Color(0xFF2F81F7);

class StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String sub;
  final Color? tone;
  const StatCard(this.label, this.value, this.sub, {super.key, this.tone});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF21293B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: kDim, fontSize: 11),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: tone ?? kInk,
            ),
          ),
          if (sub.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                sub,
                style: const TextStyle(color: kDim, fontSize: 11),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  const SectionTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: kDim,
      ),
    ),
  );
}

class PaddedCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const PaddedCard(
    this.child, {
    super.key,
    this.padding = const EdgeInsets.all(12),
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: kCard,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: const Color(0xFF21293B)),
    ),
    child: child,
  );
}

void showSnack(BuildContext context, String msg, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(msg),
      backgroundColor: error ? kWarn : kCard,
      behavior: SnackBarBehavior.floating,
    ),
  );
}

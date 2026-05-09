import 'package:flutter/material.dart';

class NarrowContent extends StatelessWidget {
  const NarrowContent({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 48),
          child: child,
        ),
      ),
    );
  }
}

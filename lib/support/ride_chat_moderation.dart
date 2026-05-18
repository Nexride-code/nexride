/// Lightweight client-side chat moderation (warn-only before send).
class RideChatModerationWarning {
  const RideChatModerationWarning({required this.reason});

  final String reason;
}

final RegExp _phonePattern = RegExp(
  r'(\+?\d{1,4}[\s-]?)?(\(?\d{2,4}\)?[\s-]?)?\d{3,4}[\s-]?\d{3,4}',
);

final RegExp _whatsAppPattern = RegExp(
  r'(wa\.me|whatsapp|whats\s*app)',
  caseSensitive: false,
);

final List<RegExp> _sexualPhrasePatterns = <RegExp>[
  RegExp(r'\b(nude|nudes|naked|sex|sexual|porn|hookup)\b', caseSensitive: false),
  RegExp(r'\b(send\s+pics|send\s+photo|explicit)\b', caseSensitive: false),
];

final List<RegExp> _harassmentPatterns = <RegExp>[
  RegExp(r'\b(kill\s+you|i\s+will\s+hurt|rape|stab|shoot\s+you)\b', caseSensitive: false),
  RegExp(r'\b(fuck\s+you|bitch|idiot|stupid\s+driver|stupid\s+rider)\b', caseSensitive: false),
];

RideChatModerationWarning? scanRideChatMessage(String text) {
  final normalized = text.trim();
  if (normalized.isEmpty) {
    return null;
  }

  if (_whatsAppPattern.hasMatch(normalized)) {
    return const RideChatModerationWarning(
      reason: 'off-platform contact (WhatsApp)',
    );
  }

  if (_phonePattern.hasMatch(normalized)) {
    return const RideChatModerationWarning(
      reason: 'private phone number',
    );
  }

  for (final pattern in _sexualPhrasePatterns) {
    if (pattern.hasMatch(normalized)) {
      return const RideChatModerationWarning(
        reason: 'sexual content',
      );
    }
  }

  for (final pattern in _harassmentPatterns) {
    if (pattern.hasMatch(normalized)) {
      return const RideChatModerationWarning(
        reason: 'harassment or threats',
      );
    }
  }

  return null;
}

const String rideChatModerationDialogBody =
    'This message may violate NexRide safety policy.';

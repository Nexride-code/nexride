import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Official Instagram + placeholder socials; legal line.
class SiteFooter extends StatelessWidget {
  const SiteFooter({super.key, required this.compact});

  final bool compact;

  static const instagram =
      'https://www.instagram.com/nexride_dynamic_journey?igsh=MXV5dWd3Zjk3OTVsZA==';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final year = DateTime.now().year;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 16 : 24,
            vertical: compact ? 12 : 16,
          ),
          child: compact
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _socialRow(context),
                    const SizedBox(height: 8),
                    Text(
                      '© $year NexRide Africa',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: _socialRow(context)),
                    Text(
                      '© $year NexRide Africa',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _socialRow(BuildContext context) {
    // ignore: prefer_const_constructors — Instagram chip is non-const (url launch).
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // ignore: prefer_const_constructors — ActionChip uses async url launch.
        _SocialChip(
          icon: Icons.camera_alt_outlined,
          label: 'Instagram',
          url: instagram,
        ),
        const _SocialChip(
          icon: Icons.facebook,
          label: 'Facebook (soon)',
          url: null,
        ),
        const _SocialChip(
          icon: Icons.music_note_rounded,
          label: 'TikTok (soon)',
          url: null,
        ),
        const _SocialChip(
          icon: Icons.tag,
          label: 'X (soon)',
          url: null,
        ),
      ],
    );
  }
}

class _SocialChip extends StatelessWidget {
  const _SocialChip({
    required this.icon,
    required this.label,
    required this.url,
  });

  final IconData icon;
  final String label;
  final String? url;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = url != null && url!.isNotEmpty;
    return ActionChip(
      avatar: Icon(icon, size: 18, color: scheme.primary),
      label: Text(label),
      onPressed: enabled
          ? () async {
              final u = Uri.parse(url!);
              if (await canLaunchUrl(u)) {
                await launchUrl(u, mode: LaunchMode.externalApplication);
              }
            }
          : null,
    );
  }
}

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../legal/legal_contacts.dart';
import '../legal/legal_models.dart';
import '../legal/legal_policy_catalog.dart';
import '../legal/legal_theme.dart';
import 'legal_policy_reader_screen.dart';

class LegalTrustCenterScreen extends StatefulWidget {
  const LegalTrustCenterScreen({
    super.key,
    this.audience = LegalAudience.rider,
  });

  final LegalAudience audience;

  @override
  State<LegalTrustCenterScreen> createState() => _LegalTrustCenterScreenState();
}

class _LegalTrustCenterScreenState extends State<LegalTrustCenterScreen> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<LegalPolicyDocument> get _filtered {
    final query = _searchController.text;
    return LegalPolicyCatalog.documentsFor(widget.audience)
        .where((d) => d.matchesQuery(query))
        .toList();
  }

  Map<LegalPolicyGroup, List<LegalPolicyDocument>> get _grouped {
    final map = <LegalPolicyGroup, List<LegalPolicyDocument>>{};
    for (final doc in _filtered) {
      map.putIfAbsent(doc.group, () => <LegalPolicyDocument>[]).add(doc);
    }
    return map;
  }

  Future<void> _openPolicy(LegalPolicyDocument doc) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => LegalPolicyReaderScreen(
          policyId: doc.id,
          audience: widget.audience,
          source: 'trust_center',
          initialQuery: _searchController.text,
        ),
      ),
    );
  }

  Future<void> _launchEmail(String email) async {
    final uri = Uri(scheme: 'mailto', path: email);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _grouped;
    final groupOrder = LegalPolicyGroup.values
        .where((g) => grouped.containsKey(g))
        .toList();

    return Theme(
      data: LegalTheme.readerTheme(),
      child: Scaffold(
        backgroundColor: LegalTheme.cream,
        appBar: AppBar(
          title: const Text('Legal & Trust'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: SafeArea(
          top: false,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              LegalTheme.gold.withValues(alpha: 0.22),
                              LegalTheme.creamDeep,
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(color: LegalTheme.divider),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: LegalTheme.card,
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: const Icon(
                                    Icons.verified_user_rounded,
                                    color: LegalTheme.goldDark,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'Trust & Legal Center',
                                    style:
                                        Theme.of(context).textTheme.headlineSmall,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'Transparent policies for riders, drivers, and merchants across Nigeria. '
                              'Review terms, privacy, safety, and payments before you ride.',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _searchController,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          hintText: 'Search policies (e.g. NDPC, refund, SOS)…',
                          prefixIcon: const Icon(Icons.search_rounded),
                          filled: true,
                          fillColor: LegalTheme.card,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide:
                                const BorderSide(color: LegalTheme.divider),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'CONTACT',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _ContactChip(
                            label: 'Support',
                            email: LegalContacts.support,
                            icon: Icons.support_agent_outlined,
                            onTap: () => _launchEmail(LegalContacts.support),
                          ),
                          _ContactChip(
                            label: 'Safety',
                            email: LegalContacts.safety,
                            icon: Icons.health_and_safety_outlined,
                            onTap: () => _launchEmail(LegalContacts.safety),
                          ),
                          _ContactChip(
                            label: 'Privacy',
                            email: LegalContacts.privacy,
                            icon: Icons.privacy_tip_outlined,
                            onTap: () => _launchEmail(LegalContacts.privacy),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (groupOrder.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Text(
                      'No policies match your search.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final group = groupOrder[index];
                      final docs = grouped[group]!;
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              docs.first.groupTitle.toUpperCase(),
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            const SizedBox(height: 8),
                            ...docs.map(
                              (doc) => _PolicyTile(
                                document: doc,
                                onTap: () => _openPolicy(doc),
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      );
                    },
                    childCount: groupOrder.length,
                  ),
                ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContactChip extends StatelessWidget {
  const _ContactChip({
    required this.label,
    required this.email,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final String email;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(icon, size: 18, color: LegalTheme.goldDark),
      label: Text('$label · $email', style: const TextStyle(fontSize: 12)),
      backgroundColor: LegalTheme.card,
      side: const BorderSide(color: LegalTheme.divider),
      onPressed: onTap,
    );
  }
}

class _PolicyTile extends StatelessWidget {
  const _PolicyTile({required this.document, required this.onTap});

  final LegalPolicyDocument document;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: LegalTheme.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: LegalTheme.divider),
      ),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: LegalTheme.goldSoft.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(document.icon, color: LegalTheme.goldDark),
        ),
        title: Text(
          document.title,
          style: const TextStyle(fontWeight: FontWeight.w700, color: LegalTheme.ink),
        ),
        subtitle: Text(
          '${document.summary}\nUpdated ${document.lastUpdatedLabel}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(height: 1.35, color: LegalTheme.inkMuted),
        ),
        trailing: const Icon(Icons.chevron_right_rounded, color: LegalTheme.goldDark),
        onTap: onTap,
      ),
    );
  }
}

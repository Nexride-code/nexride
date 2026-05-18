import 'package:flutter/material.dart';

import '../legal/legal_models.dart';
import '../legal/legal_policy_analytics_service.dart';
import '../legal/legal_policy_catalog.dart';
import '../legal/legal_policy_registry_service.dart';
import '../legal/legal_theme.dart';
import '../widgets/legal/legal_section_card.dart';

class LegalPolicyReaderScreen extends StatefulWidget {
  const LegalPolicyReaderScreen({
    super.key,
    required this.policyId,
    this.audience = LegalAudience.rider,
    this.source = 'trust_center',
    this.initialQuery = '',
  });

  final LegalPolicyId policyId;
  final LegalAudience audience;
  final String source;
  final String initialQuery;

  @override
  State<LegalPolicyReaderScreen> createState() =>
      _LegalPolicyReaderScreenState();
}

class _LegalPolicyReaderScreenState extends State<LegalPolicyReaderScreen> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final Set<int> _loggedScrollMilestones = <int>{};

  String? _versionLabel;

  LegalPolicyDocument? get _document =>
      LegalPolicyCatalog.byId(widget.policyId);

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.isNotEmpty) {
      _searchController.text = widget.initialQuery;
    }
    _scrollController.addListener(_onScroll);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final doc = _document;
    if (doc == null) {
      return;
    }
    final versions = await LegalPolicyRegistryService.instance.loadVersions();
    final version = versions.forKey(doc.versionKey) ?? doc.versionKey ?? '';
    if (mounted) {
      setState(() => _versionLabel = version);
    }
    await LegalPolicyAnalyticsService.instance.logPolicyOpened(
      policyId: doc.id,
      audience: widget.audience.name,
      version: version.isEmpty ? null : version,
      source: widget.source,
    );
  }

  void _onScroll() {
    if (!_scrollController.hasClients) {
      return;
    }
    final max = _scrollController.position.maxScrollExtent;
    if (max <= 0) {
      return;
    }
    final percent = ((_scrollController.offset / max) * 100).round();
    for (final milestone in <int>[25, 50, 75, 100]) {
      if (percent >= milestone && _loggedScrollMilestones.add(milestone)) {
        LegalPolicyAnalyticsService.instance.logPolicyScrolled(
          policyId: widget.policyId,
          scrollPercent: milestone,
          audience: widget.audience.name,
        );
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final doc = _document;
    if (doc == null) {
      return Theme(
        data: LegalTheme.readerTheme(),
        child: Scaffold(
          appBar: AppBar(title: const Text('Policy')),
          body: const Center(child: Text('Policy not found.')),
        ),
      );
    }

    final query = _searchController.text;
    final sections = doc.sectionsMatching(query);

    return Theme(
      data: LegalTheme.readerTheme(),
      child: Scaffold(
        backgroundColor: LegalTheme.cream,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            doc.title,
                            style: Theme.of(context).textTheme.headlineSmall,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Last updated ${doc.lastUpdatedLabel}'
                            '${_versionLabel != null && _versionLabel!.isNotEmpty ? ' · v$_versionLabel' : ''}',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  fontSize: 12,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Search in this policy…',
                    prefixIcon: const Icon(Icons.search_rounded),
                    filled: true,
                    fillColor: LegalTheme.card,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(color: LegalTheme.divider),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(color: LegalTheme.divider),
                    ),
                  ),
                ),
              ),
              if (doc.summary.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      doc.summary,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Expanded(
                child: sections.isEmpty
                    ? Center(
                        child: Text(
                          'No sections match your search.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                        itemCount: sections.length + 1,
                        itemBuilder: (context, index) {
                          if (index == sections.length) {
                            return Padding(
                              padding: const EdgeInsets.only(top: 8, bottom: 16),
                              child: Text(
                                'This document is provided for transparency and may be updated. '
                                'Final counsel-approved text may replace section content without changing your rights under applicable law.',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      fontSize: 12,
                                      fontStyle: FontStyle.italic,
                                    ),
                              ),
                            );
                          }
                          return LegalSectionCard(section: sections[index]);
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

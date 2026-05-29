import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/admin/models/admin_models.dart';
import 'package:nexride_driver/admin/widgets/admin_identity_reviews_panel.dart';

AdminIdentityReview _review({
  required String driverId,
  required String status,
  List<String> claimTypes = const <String>[],
  List<String> workerIds = const <String>[],
  List<String> businessIds = const <String>[],
  String serviceType = 'bike_dispatch',
  String ownershipMode = 'individual',
  String businessId = '',
}) {
  return AdminIdentityReview(
    driverId: driverId,
    status: status,
    duplicateReviewRequired: status == 'duplicate_review_required',
    matchedClaimTypes: claimTypes,
    blockingClaimTypes: status == 'duplicate_review_required' ? claimTypes : const <String>[],
    warningClaimTypes: status == 'warning' ? claimTypes : const <String>[],
    matchedWorkerIds: workerIds,
    matchedWorkerCount: workerIds.length,
    matchedBusinessIds: businessIds,
    createdAt: null,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    resolved: false,
    resolutionStatus: '',
    driverName: 'Rider $driverId',
    phone: '+2348010000000',
    email: '',
    serviceType: serviceType,
    ownershipMode: ownershipMode,
    businessId: businessId,
    dispatchVehicleType: 'bike',
  );
}

Widget _host(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: child),
    ),
  );
}

void main() {
  group('AdminIdentityReviewsPanel', () {
    testWidgets('lists reviews with status chips after load', (tester) async {
      await tester.pumpWidget(
        _host(
          AdminIdentityReviewsPanel(
            onFetchPage: ({String? cursor, String? status, bool flaggedOnly = false}) async {
              return AdminIdentityReviewsPageResult(
                reviews: <AdminIdentityReview>[
                  _review(
                    driverId: 'drv_dup',
                    status: 'duplicate_review_required',
                    claimTypes: <String>['nin'],
                    workerIds: <String>['drv_fleet'],
                    businessIds: <String>['biz_1'],
                  ),
                  _review(
                    driverId: 'drv_warn',
                    status: 'warning',
                    claimTypes: <String>['phone'],
                    workerIds: <String>['drv_other'],
                  ),
                ],
                nextCursor: null,
                hasMore: false,
              );
            },
            onFetchDetail: (String id) async => null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('identity_review_card_drv_dup')), findsOneWidget);
      expect(find.byKey(const Key('identity_review_card_drv_warn')), findsOneWidget);
      // Status chips render humanized (title-cased) labels.
      expect(find.text('Duplicate Review Required'), findsWidgets);
      expect(find.text('Warning'), findsWidgets);
    });

    testWidgets('empty page shows empty state', (tester) async {
      await tester.pumpWidget(
        _host(
          AdminIdentityReviewsPanel(
            onFetchPage: ({String? cursor, String? status, bool flaggedOnly = false}) async =>
                AdminIdentityReviewsPageResult.empty,
            onFetchDetail: (String id) async => null,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No identity reviews on this page'), findsOneWidget);
    });

    testWidgets('tapping a row opens read-only detail with matched ids/types', (tester) async {
      String? detailRequestedFor;
      await tester.pumpWidget(
        _host(
          AdminIdentityReviewsPanel(
            onFetchPage: ({String? cursor, String? status, bool flaggedOnly = false}) async =>
                AdminIdentityReviewsPageResult(
              reviews: <AdminIdentityReview>[
                _review(
                  driverId: 'drv_dup',
                  status: 'duplicate_review_required',
                  claimTypes: <String>['nin', 'bank_account'],
                  workerIds: <String>['drv_fleet'],
                  businessIds: <String>['biz_1'],
                ),
              ],
              nextCursor: null,
              hasMore: false,
            ),
            onFetchDetail: (String id) async {
              detailRequestedFor = id;
              return _review(
                driverId: id,
                status: 'duplicate_review_required',
                claimTypes: <String>['nin', 'bank_account'],
                workerIds: <String>['drv_fleet'],
                businessIds: <String>['biz_1'],
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('identity_review_card_drv_dup')));
      await tester.pumpAndSettle();

      expect(detailRequestedFor, 'drv_dup');
      expect(find.text('Identity review'), findsOneWidget);
      expect(find.text('Matched worker ids'), findsOneWidget);
      expect(find.text('Matched business ids'), findsOneWidget);
      expect(find.text('drv_fleet'), findsWidgets);
      expect(find.text('biz_1'), findsWidgets);
      // Observe-only note present in detail.
      expect(
        find.textContaining('Observe-only'),
        findsWidgets,
      );
      // No resolve/clear action button anywhere.
      expect(find.widgetWithText(ElevatedButton, 'Resolve'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Clear'), findsNothing);
    });

    testWidgets('pagination: Next advances cursor, Previous goes back', (tester) async {
      final List<String?> requestedCursors = <String?>[];
      await tester.pumpWidget(
        _host(
          AdminIdentityReviewsPanel(
            onFetchPage: ({String? cursor, String? status, bool flaggedOnly = false}) async {
              requestedCursors.add(cursor);
              if (cursor == null) {
                return AdminIdentityReviewsPageResult(
                  reviews: <AdminIdentityReview>[
                    _review(driverId: 'p1', status: 'warning'),
                  ],
                  nextCursor: 'cursor_1',
                  hasMore: true,
                );
              }
              return AdminIdentityReviewsPageResult(
                reviews: <AdminIdentityReview>[
                  _review(driverId: 'p2', status: 'clear'),
                ],
                nextCursor: null,
                hasMore: false,
              );
            },
            onFetchDetail: (String id) async => null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('identity_review_card_p1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('identity_reviews_next')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('identity_review_card_p2')), findsOneWidget);
      expect(requestedCursors, <String?>[null, 'cursor_1']);

      await tester.tap(find.byKey(const Key('identity_reviews_prev')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('identity_review_card_p1')), findsOneWidget);
      expect(requestedCursors.last, null);
    });

    testWidgets('status filter triggers a reload with the chosen status', (tester) async {
      final List<String?> requestedStatuses = <String?>[];
      await tester.pumpWidget(
        _host(
          AdminIdentityReviewsPanel(
            onFetchPage: ({String? cursor, String? status, bool flaggedOnly = false}) async {
              requestedStatuses.add(status);
              return AdminIdentityReviewsPageResult.empty;
            },
            onFetchDetail: (String id) async => null,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(requestedStatuses.first, isNull); // initial load = all

      await tester.tap(find.byKey(const Key('identity_reviews_status_filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Duplicate review required').last);
      await tester.pumpAndSettle();

      expect(requestedStatuses.last, 'duplicate_review_required');
    });
  });

  group('AdminIdentityReview.fromMap', () {
    test('parses fields and never trusts hashes', () {
      final AdminIdentityReview r = AdminIdentityReview.fromMap(<String, dynamic>{
        'driver_id': 'drv_1',
        'identity_review_status': 'duplicate_review_required',
        'duplicate_review_required': true,
        'matched_claim_types': <String>['nin', 'bank_account'],
        'blocking_claim_types': <String>['nin'],
        'matched_worker_ids': <String>['drv_2'],
        'matched_worker_count': 1,
        'matched_business_ids': <String>['biz_1'],
        'service_type': 'bike_dispatch',
        'ownership_mode': 'individual',
        'updated_at': 1700000000000,
      });
      expect(r.driverId, 'drv_1');
      expect(r.status, 'duplicate_review_required');
      expect(r.duplicateReviewRequired, isTrue);
      expect(r.matchedClaimTypes, <String>['nin', 'bank_account']);
      expect(r.matchedWorkerIds, <String>['drv_2']);
      expect(r.matchedWorkerCount, 1);
      expect(r.matchedBusinessIds, <String>['biz_1']);
      expect(r.isFlagged, isTrue);
    });
  });
}

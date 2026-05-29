import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/admin/models/admin_models.dart';
import 'package:nexride_driver/admin/widgets/admin_withdrawal_actions.dart';

Widget _host(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: Center(child: child),
    ),
  );
}

void main() {
  group('AdminWithdrawalActions', () {
    testWidgets('pending row shows Mark Paid and Reject buttons', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _host(
          AdminWithdrawalActions(
            status: 'pending',
            canApprove: true,
            onMarkPaid: (_) async {},
            onReject: (_) async {},
          ),
        ),
      );

      expect(find.byKey(const Key('withdrawal_mark_paid_button')), findsOneWidget);
      expect(find.byKey(const Key('withdrawal_reject_button')), findsOneWidget);
    });

    testWidgets('paid row hides actions and shows read-only badge', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _host(
          AdminWithdrawalActions(
            status: 'paid',
            canApprove: true,
            onMarkPaid: (_) async {},
            onReject: (_) async {},
          ),
        ),
      );

      expect(find.byKey(const Key('withdrawal_mark_paid_button')), findsNothing);
      expect(find.byKey(const Key('withdrawal_reject_button')), findsNothing);
      expect(find.text('Paid'), findsOneWidget);
    });

    testWidgets('rejected row hides actions and shows read-only badge', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _host(
          AdminWithdrawalActions(
            status: 'rejected',
            canApprove: true,
            onMarkPaid: (_) async {},
            onReject: (_) async {},
          ),
        ),
      );

      expect(find.byKey(const Key('withdrawal_mark_paid_button')), findsNothing);
      expect(find.byKey(const Key('withdrawal_reject_button')), findsNothing);
      expect(find.text('Rejected'), findsOneWidget);
    });

    testWidgets('buttons disabled without approve permission', (
      WidgetTester tester,
    ) async {
      bool markCalled = false;
      await tester.pumpWidget(
        _host(
          AdminWithdrawalActions(
            status: 'pending',
            canApprove: false,
            onMarkPaid: (_) async {
              markCalled = true;
            },
            onReject: (_) async {},
          ),
        ),
      );

      final ElevatedButton markPaid = tester.widget<ElevatedButton>(
        find.byKey(const Key('withdrawal_mark_paid_button')),
      );
      expect(markPaid.onPressed, isNull);
      await tester.tap(
        find.byKey(const Key('withdrawal_mark_paid_button')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(markCalled, isFalse);
    });

    testWidgets('Mark Paid requires a payout reference', (
      WidgetTester tester,
    ) async {
      String? captured;
      await tester.pumpWidget(
        _host(
          AdminWithdrawalActions(
            status: 'pending',
            canApprove: true,
            onMarkPaid: (String ref) async {
              captured = ref;
            },
            onReject: (_) async {},
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('withdrawal_mark_paid_button')));
      await tester.pumpAndSettle();

      // Confirm with empty reference -> validation error, callback not invoked.
      await tester.tap(find.byKey(const Key('withdrawal_mark_paid_confirm')));
      await tester.pumpAndSettle();
      expect(captured, isNull);
      expect(find.text('Payout reference is required.'), findsOneWidget);

      // Enter a reference -> confirm -> callback invoked, dialog closes.
      await tester.enterText(
        find.byKey(const Key('withdrawal_payout_reference_field')),
        'TRX-12345',
      );
      await tester.tap(find.byKey(const Key('withdrawal_mark_paid_confirm')));
      await tester.pumpAndSettle();
      expect(captured, 'TRX-12345');
      expect(find.byKey(const Key('withdrawal_mark_paid_confirm')), findsNothing);
    });

    testWidgets('Reject requires a reason', (WidgetTester tester) async {
      String? captured;
      await tester.pumpWidget(
        _host(
          AdminWithdrawalActions(
            status: 'pending',
            canApprove: true,
            onMarkPaid: (_) async {},
            onReject: (String reason) async {
              captured = reason;
            },
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('withdrawal_reject_button')));
      await tester.pumpAndSettle();

      // Confirm with empty reason -> validation error, callback not invoked.
      await tester.tap(find.byKey(const Key('withdrawal_reject_confirm')));
      await tester.pumpAndSettle();
      expect(captured, isNull);
      expect(find.text('A rejection reason is required.'), findsOneWidget);

      // Enter a reason -> confirm -> callback invoked.
      await tester.enterText(
        find.byKey(const Key('withdrawal_reject_reason_field')),
        'Suspected duplicate account',
      );
      await tester.tap(find.byKey(const Key('withdrawal_reject_confirm')));
      await tester.pumpAndSettle();
      expect(captured, 'Suspected duplicate account');
      expect(find.byKey(const Key('withdrawal_reject_confirm')), findsNothing);
    });
  });

  group('AdminWithdrawalRecord enrichment parsing', () {
    test('parses Slice 1 enrichment fields from list-page entry', () {
      final AdminWithdrawalRecord record =
          AdminWithdrawalRecord.fromAdminListPageEntry('w1', <String, dynamic>{
        'entity_type': 'driver',
        'driver_id': 'drv_1',
        'driver_name': 'Independent Rider',
        'amount': 5000,
        'status': 'pending',
        'requested_at': 1700000000000,
        'bank_name': 'Test Bank',
        'bank_code': '058',
        'account_number': '0123456789',
        'account_holder_name': 'Independent Rider',
        'user_type': 'independent_dispatch',
        'wallet_source': 'driver_wallet',
        'service_type': 'bike_dispatch',
        'ownership_mode': 'individual',
        'business_id': 'biz_9',
        'dispatch_vehicle_type': 'bike',
      });

      expect(record.bankCode, '058');
      expect(record.userType, 'independent_dispatch');
      expect(record.walletSource, 'driver_wallet');
      expect(record.serviceType, 'bike_dispatch');
      expect(record.ownershipMode, 'individual');
      expect(record.businessId, 'biz_9');
      expect(record.dispatchVehicleType, 'bike');
      expect(record.isPending, isTrue);
    });

    test('missing enrichment fields default to empty', () {
      final AdminWithdrawalRecord record =
          AdminWithdrawalRecord.fromAdminListPageEntry('w2', <String, dynamic>{
        'entity_type': 'merchant',
        'merchant_id': 'merch_1',
        'amount': 9000,
        'status': 'paid',
      });

      expect(record.bankCode, '');
      expect(record.userType, '');
      expect(record.walletSource, '');
      expect(record.businessId, '');
      expect(record.isPending, isFalse);
    });
  });

  group('AdminWithdrawalsPageResult pagination passthrough', () {
    test('preserves nextCursor and hasMore for paging', () {
      const AdminWithdrawalsPageResult page = AdminWithdrawalsPageResult(
        withdrawals: <AdminWithdrawalRecord>[],
        nextCursor: 'cursor_2',
        hasMore: true,
      );
      expect(page.nextCursor, 'cursor_2');
      expect(page.hasMore, isTrue);
    });
  });
}

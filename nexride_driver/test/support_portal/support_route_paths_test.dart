import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/support_portal/models/support_models.dart';
import 'package:nexride_driver/support_portal/support_config.dart';

void main() {
  test('/support defaults to support login', () {
    final resolution = SupportRoutePaths.resolve(
      null,
      startupUri: Uri.parse('https://nexride-8d5bc.web.app/support'),
    );

    expect(resolution.routePath, SupportRoutePaths.login);
    expect(resolution.initialView, SupportInboxView.dashboard);
  });

  test('/support/dashboard resolves directly from startup path', () {
    final resolution = SupportRoutePaths.resolve(
      null,
      startupUri: Uri.parse('https://nexride-8d5bc.web.app/support/dashboard'),
    );

    expect(resolution.routePath, SupportRoutePaths.dashboard);
    expect(resolution.initialView, SupportInboxView.dashboard);
  });

  test('/support/login resolves directly from startup path', () {
    final resolution = SupportRoutePaths.resolve(
      null,
      startupUri: Uri.parse('https://nexride-8d5bc.web.app/support/login'),
    );

    expect(resolution.routePath, SupportRoutePaths.login);
    expect(resolution.initialView, SupportInboxView.dashboard);
  });

  test('explicit navigator route beats the original startup url', () {
    final resolution = SupportRoutePaths.resolve(
      SupportRoutePaths.dashboard,
      startupUri: Uri.parse('https://nexride-8d5bc.web.app/support/login'),
    );

    expect(resolution.routePath, SupportRoutePaths.dashboard);
  });

  test('hash fragments do not override support path routes', () {
    final resolution = SupportRoutePaths.resolve(
      null,
      startupUri: Uri(
        scheme: 'https',
        host: 'nexride-8d5bc.web.app',
        path: '/support/login',
        fragment: '/dashboard',
      ),
    );

    expect(resolution.routePath, SupportRoutePaths.login);
    expect(resolution.initialView, SupportInboxView.dashboard);
  });

  test('unknown support routes fall back to login', () {
    final resolution = SupportRoutePaths.resolve(
      '/support/unknown',
      startupUri: Uri.parse('https://nexride-8d5bc.web.app/support/unknown'),
    );

    expect(resolution.routePath, SupportRoutePaths.login);
  });
}

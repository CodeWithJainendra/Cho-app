import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Service for launching the ABDM/PHR app with face auth URL.
/// Mirrors the React Native OpenAbdmModule behavior exactly.
class AbdmService {
  static const _channel = MethodChannel('com.example.cho_app/abdm');

  /// Known ABDM app package names (same order as reference app).
  static const List<String> abdmPackageNames = [
    'in.ndhm.phr.debug',
    'in.ndhm.phr',
    'in.gov.abdm.phr',
    'in.abdm.phr',
  ];

  /// Try to open ABDM app with the face auth URL.
  /// Returns the package name on success, or null if all attempts fail.
  static Future<String?> openAbdmApp(String faceAuthUrl) async {
    if (!Platform.isAndroid) {
      // On iOS or other platforms, try url_launcher
      final uri = Uri.parse(faceAuthUrl);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return 'url_launcher';
      }
      return null;
    }

    // Android: Try native platform channel (same as OpenAbdmModule.kt)
    for (final packageName in abdmPackageNames) {
      try {
        final result = await _channel.invokeMethod('openAbdmApp', {
          'url': faceAuthUrl,
          'packageName': packageName,
        });
        if (result == true) {
          return packageName;
        }
      } on PlatformException catch (_) {
        // Package not found, try next
        continue;
      }
    }

    // Fallback: Try url_launcher with intent URL
    try {
      final intentUrl = Uri.parse(
        'intent:#Intent;package=in.ndhm.phr.debug;'
        'action=android.intent.action.VIEW;'
        'S.browser_fallback_url=${Uri.encodeComponent(faceAuthUrl)};end',
      );
      if (await canLaunchUrl(intentUrl)) {
        await launchUrl(intentUrl, mode: LaunchMode.externalApplication);
        return 'intent_fallback';
      }
    } catch (_) {}

    return null;
  }

  /// Check if any ABDM app is installed.
  static Future<String?> findInstalledAbdmApp() async {
    if (!Platform.isAndroid) return null;

    for (final packageName in abdmPackageNames) {
      try {
        final installed = await _channel.invokeMethod('isAppInstalled', {
          'packageName': packageName,
        });
        if (installed == true) return packageName;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// Open Play Store for ABDM app installation.
  static Future<bool> openPlayStore() async {
    if (Platform.isAndroid) {
      try {
        final result = await _channel.invokeMethod('openPlayStore', {
          'packageName': 'in.ndhm.phr',
        });
        return result == true;
      } catch (_) {}
    }

    // Fallback to url_launcher
    final uri = Uri.parse(
      'https://play.google.com/store/apps/details?id=in.ndhm.phr',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return true;
    }
    return false;
  }
}

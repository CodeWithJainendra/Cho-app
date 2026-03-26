import 'package:flutter/material.dart';

class AppColors {
  static const Color primary = Color(0xFF1AB5A5);
  static const Color primaryLight = Color(0xFF3DD4C4);
  static const Color primaryDark = Color(0xFF0F9A8C);
  static const Color primaryDeep = Color(0xFF0D8377);
  static const Color accent = Color(0xFF1AB5A5);
  static const Color accentLight = Color(0xFF5CEBD9);
  static const Color accentSoft = Color(0xFFE5F9F7);
  static const Color secondary = Color(0xFF5B8A72);
  static const Color secondaryLight = Color(0xFF7BAF98);
  static const Color surface = Color(0xFFF8FFFE);
  static const Color card = Color(0xFFFFFFFF);
  static const Color cardBorder = Color(0xFFE8ECEF);
  static const Color divider = Color(0xFFEEF2F5);
  static const Color inputFill = Color(0xFFF5F7F9);
  static const Color textPrimary = Color(0xFF1A1D2E);
  static const Color textSecondary = Color(0xFF7B8794);
  static const Color textHint = Color(0xFFB0B8C1);
  static const Color textWhite = Color(0xFFFFFFFF);
  static const Color textOnPrimary = Color(0xFFFFFFFF);
  static const Color textOnAccent = Color(0xFF0D4A44);
  static const Color success = Color(0xFF3A8B5C);
  static const Color warning = Color(0xFFE8993E);
  static const Color error = Color(0xFFE05252);
  static const Color info = Color(0xFF4578B8);
  static const Color apple = Color(0xFF0D1A52);
  static const Color pageBackground = Color(0xFFE6F7FA);

  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF1AB5A5), Color(0xFF0F9A8C)],
  );

  static const LinearGradient splashGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF0D8377), Color(0xFF1AB5A5), Color(0xFF3DD4C4)],
  );

  static const LinearGradient headerGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF15A595), Color(0xFF1AB5A5), Color(0xFF28C9B8)],
  );
}

class AppStrings {
  static const String appName = 'CHO';
  static const String splashBrand = 'Dhurandhar.';
  static const String appFullName = 'Community Health Officer';
  static const String appTagline = "Let's Get You Set Up\nfor Success";
  static const String appDescription =
      'Organize your workflow and manage tasks easily\nall in one simple, powerful app.';
  static const String getStarted = 'Get Started';
  static const String loginHeader =
      'Log in to stay on\ntop of your tasks\nand projects.';
  static const String loginTitle = 'Login';
  static const String loginSubtitle = "Don’t Have An Account? Sign Up";
  static const String signUpHeader =
      'Create Your Account\nand Simplify Your\nWorkday';
  static const String signUpTitle = 'Sign up';
  static const String signUpSubtitle = "Already Have An Account? Login";
  static const String email = 'Email';
  static const String password = 'Password';
  static const String login = 'Login';
  static const String signUp = 'Sign up';
  static const String forgotPassword = 'Forgot Password?';
  static const String dashboard = 'Dashboard';
  static const String poweredBy = 'POWERED BY DHANVANTARI';
}

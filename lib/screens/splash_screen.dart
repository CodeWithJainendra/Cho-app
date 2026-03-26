import 'package:animate_do/animate_do.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/constants.dart';
import 'login_page.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  Future<void> _openLogin(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_seen_splash', true);
    if (!context.mounted) return;
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const LoginPage(),
        transitionsBuilder: (_, animation, __, child) {
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(1, 0),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: const Color(0xFFE9F7FA),
      body: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: size.height * 0.62,
            child: Container(
              decoration: const BoxDecoration(gradient: AppColors.headerGradient),
              child: Stack(
                children: [
                  const _TopDecorations(),
                  Center(
                    child: FadeInDown(
                      duration: const Duration(milliseconds: 700),
                      child: const _SplashArt(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: FadeInUp(
              duration: const Duration(milliseconds: 700),
              child: Container(
                padding: const EdgeInsets.fromLTRB(30, 34, 30, 28),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(34),
                    topRight: Radius.circular(34),
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        AppStrings.splashBrand,
                        style: GoogleFonts.poppins(
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                          fontStyle: FontStyle.italic,
                          color: AppColors.primary,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        AppStrings.appTagline,
                        textAlign: TextAlign.center,
                        style: GoogleFonts.poppins(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          height: 1.24,
                          color: Colors.black,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        AppStrings.appDescription,
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          height: 1.6,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 30),
                      SizedBox(
                        width: double.infinity,
                        height: 58,
                        child: ElevatedButton(
                          onPressed: () => _openLogin(context),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(30),
                            ),
                          ),
                          child: Text(
                            AppStrings.getStarted,
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SplashArt extends StatelessWidget {
  const _SplashArt();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 300,
      height: 300,
      child: Stack(
        children: [
          Positioned(
            left: 44,
            top: 28,
            child: Container(
              width: 92,
              height: 62,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.26)),
                color: Colors.transparent,
              ),
              child: Icon(
                Icons.image_outlined,
                size: 42,
                color: Colors.white.withValues(alpha: 0.55),
              ),
            ),
          ),
          Positioned(
            left: 90,
            top: 16,
            child: Icon(
              Icons.settings,
              size: 54,
              color: Colors.white.withValues(alpha: 0.24),
            ),
          ),
          Positioned(
            left: 74,
            top: 48,
            child: Container(
              width: 168,
              height: 186,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(22),
              ),
            ),
          ),
          Positioned(
            left: 102,
            top: 74,
            child: Container(
              width: 76,
              height: 74,
              decoration: BoxDecoration(
                color: const Color(0xFFE8FBFC),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: AppColors.primaryLight.withValues(alpha: 0.45),
                ),
              ),
            ),
          ),
          Positioned(
            left: 112,
            top: 158,
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.primaryLight, width: 6),
              ),
            ),
          ),
          Positioned(
            left: 176,
            top: 160,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _line(66, AppColors.primaryLight),
                const SizedBox(height: 10),
                _line(78, AppColors.primaryLight.withValues(alpha: 0.7)),
                const SizedBox(height: 10),
                _line(72, AppColors.primaryLight.withValues(alpha: 0.48)),
              ],
            ),
          ),
          Positioned(
            right: 34,
            bottom: 68,
            child: Container(
              width: 88,
              height: 82,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _line(42, Colors.white.withValues(alpha: 0.95)),
                    const SizedBox(height: 8),
                    _line(28, Colors.white.withValues(alpha: 0.8)),
                  ],
                ),
              ),
            ),
          ),
          const Positioned(left: 10, bottom: 22, child: _MiniPerson(leftPose: true)),
          const Positioned(right: 10, bottom: 28, child: _MiniPerson(leftPose: false)),
          Positioned(
            left: 26,
            bottom: 94,
            child: Icon(
              Icons.lightbulb_outline,
              size: 24,
              color: Colors.white.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }

  Widget _line(double width, Color color) {
    return Container(
      width: width,
      height: 8,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }
}

class _MiniPerson extends StatelessWidget {
  const _MiniPerson({required this.leftPose});

  final bool leftPose;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 52,
      height: 92,
      child: Stack(
        children: [
          Positioned(
            left: 18,
            top: 0,
            child: Container(
              width: 16,
              height: 16,
              decoration: const BoxDecoration(
                color: Color(0xFFFFD7BC),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Positioned(
            left: 12,
            top: 16,
            child: Container(
              width: 26,
              height: 34,
              decoration: BoxDecoration(
                color: leftPose ? const Color(0xFF274B69) : const Color(0xFF6C84A6),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          Positioned(
            left: leftPose ? 4 : 26,
            top: 28,
            child: Transform.rotate(
              angle: leftPose ? -0.65 : 0.65,
              child: _limb(),
            ),
          ),
          Positioned(
            left: leftPose ? 26 : 2,
            top: 30,
            child: Transform.rotate(
              angle: leftPose ? 0.55 : -0.55,
              child: _limb(),
            ),
          ),
          Positioned(
            left: 18,
            top: 48,
            child: Transform.rotate(angle: 0.12, child: _leg()),
          ),
          Positioned(
            left: 28,
            top: 48,
            child: Transform.rotate(angle: -0.12, child: _leg()),
          ),
        ],
      ),
    );
  }

  Widget _limb() => Container(
        width: 20,
        height: 4,
        decoration: BoxDecoration(
          color: const Color(0xFFFFD7BC),
          borderRadius: BorderRadius.circular(4),
        ),
      );

  Widget _leg() => Container(
        width: 4,
        height: 28,
        decoration: BoxDecoration(
          color: const Color(0xFF274B69),
          borderRadius: BorderRadius.circular(4),
        ),
      );
}

class _TopDecorations extends StatelessWidget {
  const _TopDecorations();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          top: -26,
          right: -18,
          child: Container(
            width: 116,
            height: 116,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: 0.14), width: 2),
            ),
          ),
        ),
        Positioned(
          top: 52,
          right: 24,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: 0.11), width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class GeonixLogo extends StatelessWidget {
  const GeonixLogo({super.key, this.height = 32});

  final double height;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SvgPicture.asset(
      isDark
          ? 'assets/branding/geonix_wrench_logo_dark.svg'
          : 'assets/branding/geonix_wrench_logo_light.svg',
      height: height,
    );
  }
}

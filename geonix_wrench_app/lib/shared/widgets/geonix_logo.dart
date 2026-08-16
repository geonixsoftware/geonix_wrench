import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class GeonixLogo extends StatelessWidget {
  const GeonixLogo({super.key, this.height = 32, this.onDark});

  final double height;

  /// Forces the white-text lockup regardless of theme.
  ///
  /// Needed because the block is dark in *both* themes: picking the
  /// mark by [Brightness] alone put the black-text logo on a dark block in
  /// light mode.
  final bool? onDark;

  @override
  Widget build(BuildContext context) {
    final isDark = onDark ?? Theme.of(context).brightness == Brightness.dark;
    return SvgPicture.asset(
      isDark
          ? 'assets/branding/geonix_wrench_logo_dark.svg'
          : 'assets/branding/geonix_wrench_logo_light.svg',
      height: height,
    );
  }
}

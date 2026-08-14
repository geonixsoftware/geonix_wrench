import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/auth/auth_service.dart';
import '../../core/billing/billing_controller.dart';
import '../../core/billing/billing_gate.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/utils/secure_logger.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/models/job_card.dart';
import '../../core/services/audio_upload_service.dart';
import '../../core/services/recording_controller.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/surface_card.dart';
import '../job_card/job_card_review_view.dart';
import 'widgets/audio_visualizer.dart';
import 'widgets/record_button.dart';

enum _UploadStage { none, uploading, error }

class _RecentActivityEntry {
  _RecentActivityEntry({
    required this.title,
    required this.subtitle,
    required this.time,
  });

  final String title;
  final String subtitle;
  final DateTime time;
}

class RecordView extends StatefulWidget {
  const RecordView({super.key});

  @override
  State<RecordView> createState() => _RecordViewState();
}

class _RecordViewState extends State<RecordView> {
  static const _minRecordingDuration = Duration(seconds: 1);

  final RecordingController _controller = RecordingController();
  late final AudioUploadService _uploadService;
  final List<_RecentActivityEntry> _recentActivity = [];

  _UploadStage _stage = _UploadStage.none;
  String? _pendingFilePath;

  @override
  void initState() {
    super.initState();
    _uploadService = AudioUploadService(authService: context.read<AuthService>());
    _controller.addListener(_onControllerChanged);
  }

  void _onControllerChanged() => setState(() {});

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleTap() async {
    if (_stage == _UploadStage.uploading) return;

    if (!_controller.isRecording && !context.read<BillingController>().isActive) {
      await showSubscriptionRequiredDialog(context);
      return;
    }

    if (_controller.isRecording) {
      // Lock the UI into the processing state immediately so the tap can't
      // be repeated while stop() and the upload are still in flight.
      setState(() => _stage = _UploadStage.uploading);

      final elapsed = _controller.elapsed;
      final path = await _controller.stop();
      if (path == null) {
        if (mounted) setState(() => _stage = _UploadStage.error);
        return;
      }

      if (elapsed < _minRecordingDuration) {
        await _controller.deleteRecording(path);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.t(AppStrings.recordTooShort))),
          );
          setState(() => _stage = _UploadStage.none);
        }
        _controller.reset();
        return;
      }

      await _processRecording(path);
      return;
    }

    try {
      await _controller.start();
    } on RecordingPermissionException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.t(AppStrings.recordPermissionDenied))),
      );
    }
  }

  Future<void> _processRecording(String path) async {
    setState(() {
      _stage = _UploadStage.uploading;
      _pendingFilePath = path;
    });

    var succeeded = false;
    var paywallRequired = false;
    try {
      final jobCard = await _uploadService.uploadRecording(path);
      if (!mounted) return;
      // The upload succeeded, so the local temp recording is no longer needed.
      // Delete it immediately to avoid a storage leak (do this before leaving
      // this screen, since the user may never come back to the review view).
      await _controller.deleteRecording(path);
      _addRecentActivity(jobCard);
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => JobCardReviewView(jobCard: jobCard)),
      );
      succeeded = true;
      if (mounted) _controller.reset();
    } catch (e, stackTrace) {
      AppLogger.error('RecordView: failed to process recording', e, stackTrace);
      if (e is AudioUploadException && e.isPaymentRequired) {
        // Server-side gate rejected the request (HTTP 402) — surface the
        // subscription dialog regardless of the cached client-side state.
        paywallRequired = true;
      } else if (e is AudioUploadException && e.isTimeout) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.t(AppStrings.recordTimeoutError))),
          );
        }
      }
    } finally {
      // Always leave the "uploading" state, even on an unexpected error,
      // so the UI never gets stuck on the processing screen.
      if (mounted) {
        setState(() {
          _stage = succeeded ? _UploadStage.none : _UploadStage.error;
          if (succeeded) _pendingFilePath = null;
        });
      }
    }

    if (mounted && paywallRequired) {
      await showSubscriptionRequiredDialog(context);
    }
  }

  void _addRecentActivity(JobCard jobCard) {
    final title = jobCard.vehicleInfo.trim().isNotEmpty
        ? jobCard.vehicleInfo.trim()
        : context.l10n.t(AppStrings.recordRecentActivityUntitled);
    setState(() {
      _recentActivity.insert(
        0,
        _RecentActivityEntry(
          title: title,
          subtitle: jobCard.workPerformed.trim(),
          time: DateTime.now(),
        ),
      );
      if (_recentActivity.length > 5) {
        _recentActivity.removeLast();
      }
    });
  }

  Future<void> _retry() async {
    final path = _pendingFilePath;
    if (path == null) return;
    _processRecording(path);
  }

  void _discardError() {
    setState(() {
      _stage = _UploadStage.none;
      _pendingFilePath = null;
    });
    _controller.reset();
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String _formatRelativeTime(DateTime time) {
    final l10n = context.l10n;
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return l10n.t(AppStrings.recordActivityJustNow);
    if (diff.inMinutes < 60) {
      return l10n.t(AppStrings.recordActivityMinutesAgo).replaceAll('{n}', '${diff.inMinutes}');
    }
    return l10n.t(AppStrings.recordActivityHoursAgo).replaceAll('{n}', '${diff.inHours}');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final subscriptionActive = context.watch<BillingController>().isActive;

    if (_stage == _UploadStage.uploading) {
      return _StatusView(
        icon: const SizedBox(
          width: 40,
          height: 40,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
        title: l10n.t(AppStrings.recordProcessingTitle),
        subtitle: l10n.t(AppStrings.recordProcessingSubtitle),
      );
    }

    if (_stage == _UploadStage.error) {
      return _StatusView(
        icon: Icon(Icons.error_outline_rounded, color: theme.colorScheme.error, size: 40),
        title: l10n.t(AppStrings.recordErrorTitle),
        subtitle: l10n.t(AppStrings.recordErrorSubtitle),
        action: Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 12,
          children: [
            OutlinedButton(
              onPressed: _discardError,
              child: Text(l10n.t(AppStrings.jobCardDiscard)),
            ),
            ElevatedButton(
              onPressed: _retry,
              child: Text(l10n.t(AppStrings.retry)),
            ),
          ],
        ),
      );
    }

    final isRecording = _controller.isRecording;

    return SafeArea(
      child: SingleChildScrollView(
        padding: AppTheme.screenPadding,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _StatusHeader(isRecording: isRecording),
                const SizedBox(height: 20),
                _RecordingActionCard(
                  isRecording: isRecording,
                  amplitude: _controller.amplitude,
                  elapsedLabel: _formatDuration(_controller.elapsed),
                  onPressed: _handleTap,
                  disabled: !isRecording && !subscriptionActive,
                ),
                const SizedBox(height: 20),
                _RecentActivitySection(
                  entries: _recentActivity,
                  formatRelativeTime: _formatRelativeTime,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({required this.isRecording});

  final bool isRecording;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final color = isRecording ? theme.colorScheme.error : AppColors.success;
    final label = isRecording
        ? l10n.t(AppStrings.recordStatusRecording)
        : l10n.t(AppStrings.recordStatusIdle);
    final dateLabel = DateFormat.yMMMd(l10n.locale.toString()).format(DateTime.now());

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withValues(alpha: 0.25)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
        Text(
          dateLabel,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      ],
    );
  }
}

class _RecordingActionCard extends StatelessWidget {
  const _RecordingActionCard({
    required this.isRecording,
    required this.amplitude,
    required this.elapsedLabel,
    required this.onPressed,
    this.disabled = false,
  });

  final bool isRecording;
  final double amplitude;
  final String elapsedLabel;
  final VoidCallback onPressed;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return SurfaceCard(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 24),
      child: Column(
        children: [
          Text(
            isRecording
                ? l10n.t(AppStrings.recordingTitle)
                : l10n.t(AppStrings.recordIdleTitle),
            style: theme.textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            isRecording
                ? l10n.t(AppStrings.recordingSubtitle)
                : l10n.t(AppStrings.recordIdleSubtitle),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 28),
          AudioVisualizer(amplitude: amplitude, isActive: isRecording),
          const SizedBox(height: 16),
          Text(
            elapsedLabel,
            style: theme.textTheme.displaySmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 28),
          RecordButton(isRecording: isRecording, onPressed: onPressed),
        ],
      ),
    );
  }
}

class _RecentActivitySection extends StatelessWidget {
  const _RecentActivitySection({
    required this.entries,
    required this.formatRelativeTime,
  });

  final List<_RecentActivityEntry> entries;
  final String Function(DateTime) formatRelativeTime;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.t(AppStrings.recordRecentActivityTitle), style: theme.textTheme.titleMedium),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                l10n.t(AppStrings.recordRecentActivityEmpty),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            )
          else
            for (final entry in entries) ...[
              const SizedBox(height: 12),
              _RecentActivityTile(entry: entry, timeLabel: formatRelativeTime(entry.time)),
            ],
        ],
      ),
    );
  }
}

class _RecentActivityTile extends StatelessWidget {
  const _RecentActivityTile({required this.entry, required this.timeLabel});

  final _RecentActivityEntry entry;
  final String timeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radius - 4),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(Icons.description_outlined, size: 18, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (entry.subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    entry.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            timeLabel,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusView extends StatelessWidget {
  const _StatusView({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  final Widget icon;
  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    icon,
                    const SizedBox(height: 20),
                    Text(title, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Text(
                      subtitle,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                    if (action != null) ...[
                      const SizedBox(height: 24),
                      action!,
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

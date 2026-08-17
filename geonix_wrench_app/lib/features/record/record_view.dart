import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/auth/auth_service.dart';
import '../../core/billing/billing_controller.dart';
import '../../core/billing/billing_gate.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/utils/secure_logger.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/services/audio_upload_service.dart';
import '../../core/services/pdf_service.dart';
import '../../core/services/recent_activity_store.dart';
import '../../core/services/recording_controller.dart';
import '../../core/settings/app_settings.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/app_header.dart';
import '../../shared/widgets/block_layout.dart';
import '../../shared/widgets/surface_card.dart';
import '../job_card/job_card_review_view.dart';
import 'widgets/audio_visualizer.dart';
import 'widgets/record_button.dart';

enum _UploadStage { none, uploading, error }

String _formatDuration(Duration duration) {
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
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

  _UploadStage _stage = _UploadStage.none;
  String? _pendingFilePath;

  /// The recent-activity row currently re-fetching its PDF, if any.
  int? _downloadingJobCardId;

  /// Whether the current error is one retrying cannot fix. Drives whether the
  /// error screen offers a Retry button at all.
  bool _errorIsPermanent = false;

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
    var noSpeech = false;
    var permanent = false;
    try {
      final jobCard = await _uploadService.uploadRecording(path);
      if (!mounted) return;
      // The upload succeeded, so the local temp recording is no longer needed.
      // Delete it immediately to avoid a storage leak (do this before leaving
      // this screen, since the user may never come back to the review view).
      await _controller.deleteRecording(path);
      if (!mounted) return;
      await context.read<RecentActivityStore>().record(
            jobCard,
            fallbackTitle: context.l10n.t(AppStrings.recordRecentActivityUntitled),
          );
      if (!mounted) return;
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
      } else if (e is AudioUploadException && e.isNoSpeech) {
        // The recording held no speech, so re-sending the same bytes would
        // fail identically. Offering "Retry" would only waste the user's
        // time — this ends the attempt with an explanation instead.
        noSpeech = true;
        await _controller.deleteRecording(path);
      } else if (e is AudioUploadException && e.isTimeout) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.t(AppStrings.recordTimeoutError))),
          );
        }
      } else if (e is AudioUploadException && e.isPermanent) {
        // The server said this can never succeed. Keep the recording so it
        // isn't lost, but don't offer a Retry that is guaranteed to fail.
        permanent = true;
      }
    } finally {
      // Always leave the "uploading" state, even on an unexpected error,
      // so the UI never gets stuck on the processing screen. A recording with
      // no speech in it returns to idle rather than the retryable error
      // screen, since its file has already been discarded.
      if (mounted) {
        final resolved = succeeded || noSpeech;
        setState(() {
          _stage = resolved ? _UploadStage.none : _UploadStage.error;
          if (resolved) _pendingFilePath = null;
          _errorIsPermanent = permanent;
        });
      }
    }

    if (mounted && noSpeech) {
      _controller.reset();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.t(AppStrings.recordNoSpeechError))),
      );
    }

    if (mounted && paywallRequired) {
      await showSubscriptionRequiredDialog(context);
    }
  }

  /// Re-downloads a finished job's PDF from the recent-activity list.
  ///
  /// The list keeps no document itself — only the job's id — so this asks the
  /// server to render it again, saves it to the configured folder and offers
  /// the share sheet, exactly as the review screen's export button does.
  Future<void> _downloadAgain(RecentActivityEntry entry) async {
    if (_downloadingJobCardId != null) return;

    if (!context.read<BillingController>().isActive) {
      await showSubscriptionRequiredDialog(context);
      return;
    }

    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final store = context.read<RecentActivityStore>();
    final settings = context.read<AppSettings>();
    final service = PdfService(
      authService: context.read<AuthService>(),
      pdfDirectory: settings.pdfDirectory,
    );

    setState(() => _downloadingJobCardId = entry.jobCardId);
    try {
      final saved = await service.download(
        jobCardId: entry.jobCardId,
        currency: settings.currency,
      );
      await store.attachPdf(entry.jobCardId, saved.path);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('${l10n.t(AppStrings.jobCardPdfSaved)} · ${saved.parent.path}'),
        ),
      );
    } on PdfFetchException catch (e) {
      if (!mounted) return;
      if (e.isPaymentRequired) {
        await showSubscriptionRequiredDialog(context);
      } else {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.t(AppStrings.jobCardPdfError))),
        );
      }
    } catch (e, stackTrace) {
      AppLogger.error('RecordView: failed to re-download job card PDF', e, stackTrace);
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.t(AppStrings.jobCardPdfError))),
        );
      }
    } finally {
      if (mounted) setState(() => _downloadingJobCardId = null);
    }
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
      _errorIsPermanent = false;
    });
    _controller.reset();
  }

  String _formatRelativeTime(DateTime time) {
    final l10n = context.l10n;
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return l10n.t(AppStrings.recordActivityJustNow);
    if (diff.inMinutes < 60) {
      return l10n.t(AppStrings.recordActivityMinutesAgo).replaceAll('{n}', '${diff.inMinutes}');
    }
    // The list survives restarts now, so it holds entries older than a day —
    // which "31h ago" reads badly for.
    if (diff.inHours < 24) {
      return l10n.t(AppStrings.recordActivityHoursAgo).replaceAll('{n}', '${diff.inHours}');
    }
    if (diff.inDays < 7) {
      return l10n.t(AppStrings.recordActivityDaysAgo).replaceAll('{n}', '${diff.inDays}');
    }
    return DateFormat.yMMMd(l10n.locale.toString()).format(time);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final theme = Theme.of(context);
    // isLocked (not !isActive) so the record button does not render disabled
    // during the first status fetch and then snap enabled.
    final subscriptionLocked = context.watch<BillingController>().isLocked;

    if (_stage == _UploadStage.uploading) {
      return _StatusView(
        icon: SizedBox(
          width: 34,
          height: 34,
          child: CircularProgressIndicator(strokeWidth: 3, color: p.accent),
        ),
        title: l10n.t(AppStrings.recordProcessingTitle),
        subtitle: l10n.t(AppStrings.recordProcessingSubtitle),
      );
    }

    if (_stage == _UploadStage.error) {
      // A permanent fault gets no Retry button — the server has already said
      // the request can never succeed, so the only honest option is to
      // discard. The subtitle says why, rather than implying a flaky network.
      return _StatusView(
        icon: Icon(Icons.error_outline_rounded, color: theme.colorScheme.error, size: 34),
        title: l10n.t(AppStrings.recordErrorTitle),
        subtitle: l10n.t(_errorIsPermanent
            ? AppStrings.recordErrorPermanentSubtitle
            : AppStrings.recordErrorSubtitle),
        action: Column(
          children: [
            if (!_errorIsPermanent) ...[
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _retry,
                  child: Text(l10n.t(AppStrings.retry)),
                ),
              ),
              const SizedBox(height: AppTheme.space3),
            ],
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _discardError,
                child: Text(l10n.t(AppStrings.jobCardDiscard)),
              ),
            ),
          ],
        ),
      );
    }

    final isRecording = _controller.isRecording;

    return BlockScaffold(
      headerPadding: BlockScaffold.compactHeaderPadding,
      header: const _RecordHeader(),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.space5,
          AppTheme.space6,
          AppTheme.space5,
          AppTheme.navClearance,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _RecordingActionCard(
                  isRecording: isRecording,
                  // Passed as listenables so a new level or a timer tick
                  // repaints only the meter and the readout, instead of
                  // rebuilding this whole screen several times a second.
                  amplitude: _controller.amplitudeListenable,
                  elapsed: _controller.elapsedListenable,
                  onPressed: _handleTap,
                  disabled: !isRecording && subscriptionLocked,
                ),
                const SizedBox(height: AppTheme.space8),
                _RecentActivitySection(
                  formatRelativeTime: _formatRelativeTime,
                  onOpen: _downloadAgain,
                  busyJobCardId: _downloadingJobCardId,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The near-black block at the top of the record screen: wordmark, then the
/// date beside it. Nothing else.
///
/// It used to stack a 34px "Ready to record" headline and an Idle/Recording
/// chip underneath, which made the block taller than the record control it was
/// introducing — and said nothing the control below does not already say by
/// being a big red button with a running timer on it.
class _RecordHeader extends StatelessWidget {
  const _RecordHeader();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AppHeaderBar(
      label: DateFormat.yMMMEd(l10n.locale.toString()).format(DateTime.now()),
    );
  }
}

class _RecordingActionCard extends StatelessWidget {
  const _RecordingActionCard({
    required this.isRecording,
    required this.amplitude,
    required this.elapsed,
    required this.onPressed,
    this.disabled = false,
  });

  final bool isRecording;
  final ValueListenable<double> amplitude;
  final ValueListenable<Duration> elapsed;
  final VoidCallback onPressed;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return SurfaceCard(
      radius: AppTheme.radiusXl,
      padding: const EdgeInsets.symmetric(vertical: AppTheme.space8, horizontal: AppTheme.space6),
      child: Column(
        children: [
          // The meter sits in its own sunken well so it reads as an instrument
          // panel rather than free-floating bars on the card.
          SurfaceWell(
            radius: AppTheme.radiusLg,
            padding: const EdgeInsets.symmetric(
              vertical: AppTheme.space4,
              horizontal: AppTheme.space4,
            ),
            child: Column(
              children: [
                ValueListenableBuilder<double>(
                  valueListenable: amplitude,
                  builder: (context, level, _) =>
                      AudioVisualizer(amplitude: level, isActive: isRecording),
                ),
                const SizedBox(height: AppTheme.space3),
                ValueListenableBuilder<Duration>(
                  valueListenable: elapsed,
                  builder: (context, value, _) => Text(
                    _formatDuration(value),
                    style: theme.textTheme.displaySmall?.copyWith(
                      color: isRecording ? p.danger : p.ink,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppTheme.space8),
          RecordButton(
            isRecording: isRecording,
            onPressed: onPressed,
            disabled: disabled,
          ),
          const SizedBox(height: AppTheme.space6),
          Text(
            isRecording
                ? l10n.t(AppStrings.recordingSubtitle)
                : l10n.t(AppStrings.recordIdleSubtitle),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: p.inkSecondary),
          ),
        ],
      ),
    );
  }
}

class _RecentActivitySection extends StatelessWidget {
  const _RecentActivitySection({
    required this.formatRelativeTime,
    required this.onOpen,
    required this.busyJobCardId,
  });

  final String Function(DateTime) formatRelativeTime;
  final ValueChanged<RecentActivityEntry> onOpen;
  final int? busyJobCardId;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final store = context.watch<RecentActivityStore>();
    final entries = store.entries;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeading(
          title: l10n.t(AppStrings.recordRecentActivityTitle),
          trailing: entries.isEmpty
              ? null
              : ToneChip(label: '${entries.length}', tone: ChipTone.neutral),
        ),
        if (entries.isNotEmpty) ...[
          const SizedBox(height: AppTheme.space2),
          Text(
            l10n.t(AppStrings.recordRecentActivityHint),
            style: theme.textTheme.bodySmall?.copyWith(color: p.inkTertiary),
          ),
        ],
        const SizedBox(height: AppTheme.space4),
        if (entries.isEmpty)
          // An empty state on its own dashed-feeling well, rather than a grey
          // sentence floating under a heading.
          SurfaceWell(
            radius: AppTheme.radiusLg,
            padding: const EdgeInsets.symmetric(
              vertical: AppTheme.space8,
              horizontal: AppTheme.space5,
            ),
            child: Column(
              children: [
                IconTile(
                  store.limit == 0 ? Icons.history_toggle_off_rounded : Icons.description_outlined,
                  tone: TileTone.neutral,
                ),
                const SizedBox(height: AppTheme.space4),
                Text(
                  l10n.t(store.limit == 0
                      ? AppStrings.recordRecentActivityOff
                      : AppStrings.recordRecentActivityEmpty),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: p.inkTertiary),
                ),
              ],
            ),
          )
        else
          for (final entry in entries) ...[
            _RecentActivityTile(
              entry: entry,
              timeLabel: formatRelativeTime(entry.createdAt),
              busy: entry.jobCardId == busyJobCardId,
              onTap: busyJobCardId == null ? () => onOpen(entry) : null,
            ),
            if (entry != entries.last) const SizedBox(height: AppTheme.space3),
          ],
      ],
    );
  }
}

class _RecentActivityTile extends StatelessWidget {
  const _RecentActivityTile({
    required this.entry,
    required this.timeLabel,
    required this.busy,
    required this.onTap,
  });

  final RecentActivityEntry entry;
  final String timeLabel;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context);

    return SurfaceCard(
      radius: AppTheme.radiusLg,
      padding: const EdgeInsets.all(AppTheme.space4),
      onTap: onTap,
      child: Row(
        children: [
          const IconTile(Icons.description_outlined, size: 42),
          const SizedBox(width: AppTheme.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                if (entry.subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    entry.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: p.inkTertiary),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppTheme.space3),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                timeLabel,
                style: theme.textTheme.bodySmall?.copyWith(color: p.inkTertiary),
              ),
              const SizedBox(height: 4),
              // The affordance for "this row does something": a download glyph
              // that becomes the spinner for the fetch it starts.
              SizedBox(
                height: 18,
                width: 18,
                child: busy
                    ? CircularProgressIndicator(strokeWidth: 2, color: p.accent)
                    : Icon(Icons.download_rounded, size: 18, color: p.accent),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Processing and error states, kept on the same block/sheet shape as the idle
/// screen so the layout never jumps between them.
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
    final p = context.palette;
    final theme = Theme.of(context);

    return BlockScaffold(
      // Same block as the idle screen, so switching into processing or error
      // does not shunt the whole layout up and down.
      headerPadding: BlockScaffold.compactHeaderPadding,
      header: const _RecordHeader(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppTheme.space6,
                    AppTheme.space8,
                    AppTheme.space6,
                    AppTheme.navClearance,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 76,
                          height: 76,
                          decoration: BoxDecoration(
                            color: p.surfaceMuted,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: icon,
                        ),
                        const SizedBox(height: AppTheme.space6),
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall,
                        ),
                        const SizedBox(height: AppTheme.space3),
                        Text(
                          subtitle,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(color: p.inkSecondary),
                        ),
                        if (action != null) ...[
                          const SizedBox(height: AppTheme.space8),
                          action!,
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

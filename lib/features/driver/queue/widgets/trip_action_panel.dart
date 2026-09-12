import 'package:flutter/material.dart';
import '../../../../config/theme.dart';
import '../../../../core/models/trip_state.dart';
import '../../../../core/services/dispatch_service.dart';
import '../../../../core/services/trip_service.dart';

/// The driver's single source of actions for an active trip.
///
/// Renders from the live backend state, so exactly one action is offered at a
/// time and the driver can never see two contradictory buttons. Every action
/// goes through [TripService], which validates the transition server-side.
class TripActionPanel extends StatefulWidget {
  final String bookingId;

  /// Called after the trip reaches a terminal state, so the parent screen can
  /// reset its own queue/booking state.
  final VoidCallback? onTripFinished;

  const TripActionPanel({
    super.key,
    required this.bookingId,
    this.onTripFinished,
  });

  @override
  State<TripActionPanel> createState() => _TripActionPanelState();
}

class _TripActionPanelState extends State<TripActionPanel> {
  bool _busy = false;
  bool _finishedNotified = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return; // guards against double taps
    setState(() => _busy = true);
    try {
      await action();
    } on TripTransitionException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Couldn\'t save that. Check your connection and '
              'try again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<TripState>(
      stream: TripService.instance.watch(widget.bookingId),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.all(AppSpacing.lg),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
          );
        }

        final state = snapshot.data!;

        // A finished trip only clears the driver's screen once there is
        // nothing left to do on it. For a fare to be paid at the end, that
        // means after the money is in: otherwise the trip disappeared the
        // moment it was completed, taking the payment step with it.
        final nothingLeft =
            state.trip == TripStatus.cancelled ||
            (state.trip.isTerminal && state.payment.isSettled);
        if (nothingLeft && !_finishedNotified) {
          _finishedNotified = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onTripFinished?.call();
          });
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StatusLine(state: state),
            const SizedBox(height: AppSpacing.md),
            ..._actionsFor(state),
          ],
        );
      },
    );
  }

  List<Widget> _actionsFor(TripState s) {
    // Payment takes precedence once the driver is with the passenger — and
    // once the ride is over, for a fare the driver agreed to collect at the
    // end.
    if (s.trip == TripStatus.driverArrived ||
        (s.trip == TripStatus.tripCompleted && !s.payment.isSettled)) {
      switch (s.payment) {
        case PaymentState.unpaid:
          // The passenger has asked to pay at the end. The driver decides:
          // it is their fare at risk.
          if (s.payAfterPending) {
            return [
              _waitingNote(
                'The passenger asks to pay '
                '₱${s.fare.toStringAsFixed(0)} at the end of the ride.',
              ),
              const SizedBox(height: AppSpacing.sm),
              _primary(
                icon: Icons.play_circle_outline,
                label: 'Start now, pay after',
                onPressed: () => _run(
                  () => TripService.instance.answerPayAfter(
                    widget.bookingId,
                    agreed: true,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              _secondary(
                icon: Icons.payments_outlined,
                label: 'Ask for payment now',
                onPressed: () => _run(
                  () => TripService.instance.answerPayAfter(
                    widget.bookingId,
                    agreed: false,
                  ),
                ),
              ),
            ];
          }
          // Agreed to be paid at the end: nothing to wait for here, the
          // trip switch below offers Start Trip.
          if (s.payAfterAgreed && s.trip == TripStatus.driverArrived) break;
          if (s.trip == TripStatus.tripCompleted) {
            return [
              _waitingNote(
                'The ride is over. Waiting for the passenger to pay '
                '₱${s.fare.toStringAsFixed(0)}.',
              ),
              const SizedBox(height: AppSpacing.sm),
              // A way out: without it a passenger who walks off without
              // paying would leave the driver stuck on this trip, unable to
              // check in again.
              _secondary(
                icon: Icons.logout,
                label: 'Finish without payment',
                danger: true,
                onPressed: _confirmFinishUnpaid,
              ),
            ];
          }
          return [
            _waitingNote(
              'Waiting for the passenger to pay ₱${s.fare.toStringAsFixed(0)}.',
            ),
          ];
        case PaymentState.paymentSubmitted:
          return [
            _primary(
              icon: Icons.fact_check_outlined,
              label: 'Verify Payment',
              onPressed: () => _run(
                () => TripService.instance.movePayment(
                  bookingId: widget.bookingId,
                  to: PaymentState.paymentVerifying,
                  by: TripRole.driver,
                ),
              ),
            ),
          ];
        case PaymentState.paymentVerifying:
          return [
            _primary(
              icon: Icons.check_circle,
              label: 'Confirm Payment',
              onPressed: () => _run(
                () => TripService.instance.movePayment(
                  bookingId: widget.bookingId,
                  to: PaymentState.paymentConfirmed,
                  by: TripRole.driver,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            _secondary(
              icon: Icons.cancel_outlined,
              label: 'Reject Payment',
              danger: true,
              onPressed: () => _run(
                () => TripService.instance.movePayment(
                  bookingId: widget.bookingId,
                  to: PaymentState.paymentRejected,
                  by: TripRole.driver,
                ),
              ),
            ),
          ];
        case PaymentState.paymentRejected:
          return [_waitingNote('Waiting for the passenger to pay again.')];
        case PaymentState.paymentConfirmed:
          break; // handled by the trip-status switch below
      }
    }

    switch (s.trip) {
      case TripStatus.requested:
        return [
          // A trip that leaves Baliwag is the driver's to refuse: it is a
          // long way back empty, even with the return charge. Saying no
          // keeps their place in the queue.
          if (s.outsideServiceArea) ...[
            _OutOfTownNotice(state: s),
            const SizedBox(height: AppSpacing.md),
          ],
          _primary(
            icon: Icons.check_circle_outline,
            label: s.outsideServiceArea
                ? 'Accept out-of-town trip'
                : 'Accept Ride',
            onPressed: () => _run(
              () => TripService.instance.moveTrip(
                bookingId: widget.bookingId,
                to: TripStatus.driverAccepted,
                by: TripRole.driver,
              ),
            ),
          ),
          if (s.outsideServiceArea) ...[
            const SizedBox(height: AppSpacing.sm),
            _secondary(
              icon: Icons.do_not_disturb_on_outlined,
              label: 'Decline — too far',
              onPressed: _confirmDeclineOutOfTown,
            ),
          ],
        ];
      case TripStatus.driverAccepted:
        return [
          _primary(
            icon: Icons.navigation_outlined,
            label: 'Go to Passenger',
            onPressed: () => _run(
              () => TripService.instance.moveTrip(
                bookingId: widget.bookingId,
                to: TripStatus.driverOnTheWay,
                by: TripRole.driver,
              ),
            ),
          ),
        ];
      case TripStatus.driverOnTheWay:
        return [
          _primary(
            icon: Icons.where_to_vote_outlined,
            label: 'Mark as Arrived',
            onPressed: () => _run(
              () => TripService.instance.moveTrip(
                bookingId: widget.bookingId,
                to: TripStatus.driverArrived,
                by: TripRole.driver,
              ),
            ),
          ),
        ];
      case TripStatus.readyToStart:
        return [
          _primary(
            icon: Icons.play_circle_outline,
            label: 'Start Trip',
            onPressed: () => _run(
              () => TripService.instance.moveTrip(
                bookingId: widget.bookingId,
                to: TripStatus.tripInProgress,
                by: TripRole.driver,
              ),
            ),
          ),
        ];
      case TripStatus.tripInProgress:
        return [
          _primary(
            icon: Icons.flag_circle_outlined,
            label: 'Complete Trip',
            onPressed: () => _confirmComplete(),
          ),
        ];
      case TripStatus.driverArrived:
        // Payment confirmed but trip not yet advanced — offer the start.
        return [
          _primary(
            icon: Icons.play_circle_outline,
            label: 'Start Trip',
            onPressed: () => _run(
              () => TripService.instance.moveTrip(
                bookingId: widget.bookingId,
                to: TripStatus.readyToStart,
                by: TripRole.driver,
              ),
            ),
          ),
        ];
      case TripStatus.tripCompleted:
      case TripStatus.cancelled:
        return [_waitingNote(s.trip.driverLabel)];
    }
  }

  /// Closes a finished trip whose fare was never paid, so the driver can get
  /// back in the queue. The trip stays on record as unpaid for the admins.
  Future<void> _confirmDeclineOutOfTown() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Decline this trip?'),
        content: const Text(
          'You keep your place in the queue, and the passenger is offered '
          'the next driver. You will not be offered this trip again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Go back'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.errorRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Decline', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await _run(() async {
      final result = await DispatchService.instance.declineOutOfTown(
        widget.bookingId,
      );
      if (!mounted) return;
      if (!result.success) {
        // The trip is declined regardless; this only says the passenger is
        // now without a driver.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.message ?? 'The passenger is waiting for another driver.',
            ),
          ),
        );
      }
    });
    // Declining ends this trip for this driver either way: the booking is
    // cancelled, so the panel has nothing left to show.
    if (mounted) widget.onTripFinished?.call();
  }

  Future<void> _confirmFinishUnpaid() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Finish without payment?'),
        content: const Text(
          'The trip stays on record as unpaid, and your TODA admin can see '
          'it. Only do this if the passenger has left without paying.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep waiting'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.errorRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Finish unpaid',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => TripService.instance.finishUnpaid(widget.bookingId));
    if (mounted) widget.onTripFinished?.call();
  }

  Future<void> _confirmComplete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Complete this trip?'),
        content: const Text(
          'Mark the trip as finished. This will move it to your history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not yet'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Yes, complete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(
      () => TripService.instance.moveTrip(
        bookingId: widget.bookingId,
        to: TripStatus.tripCompleted,
        by: TripRole.driver,
      ),
    );
  }

  Widget _primary({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return ElevatedButton.icon(
      onPressed: _busy ? null : onPressed,
      icon: _busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : Icon(icon),
      label: Text(_busy ? 'Working…' : label),
    );
  }

  Widget _secondary({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    bool danger = false,
  }) {
    return OutlinedButton.icon(
      onPressed: _busy ? null : onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: danger
          ? OutlinedButton.styleFrom(
              foregroundColor: AppTheme.errorRed,
              side: const BorderSide(color: AppTheme.errorRed),
            )
          : null,
    );
  }

  Widget _waitingNote(String text) {
    return Row(
      children: [
        Icon(Icons.schedule, size: 16, color: AppTheme.tertiaryText(context)),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }
}

/// Shows the current trip and payment state together, so the driver always
/// knows where things stand without guessing from the button label.
/// Tells the driver a trip leaves Baliwag, and what the fare already
/// includes for it, before they accept.
class _OutOfTownNotice extends StatelessWidget {
  final TripState state;
  const _OutOfTownNotice({required this.state});

  @override
  Widget build(BuildContext context) {
    final fee = state.outOfTownFee;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppTheme.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.south_east, size: 18, color: AppTheme.warning),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This trip leaves Baliwag',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text(
                  fee > 0
                      ? 'The ₱${state.fare.toStringAsFixed(0)} fare includes '
                            '₱${fee.toStringAsFixed(0)} for the '
                            '${state.outOfTownKm.toStringAsFixed(1)} km '
                            'outside town, so your return is paid for. You '
                            'can decline without losing your place.'
                      : 'Just past the town line, close to the terminal — '
                            'charged as a normal trip. You can still '
                            'decline without losing your place.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  final TripState state;
  const _StatusLine({required this.state});

  @override
  Widget build(BuildContext context) {
    final settled = state.payment.isSettled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          state.trip.driverLabel,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (!state.trip.isTerminal) ...[
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Icon(
                settled ? Icons.check_circle : Icons.schedule,
                size: 14,
                color: settled ? AppTheme.success : AppTheme.textMuted,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  state.payment.driverLabel,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: settled ? AppTheme.success : null,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

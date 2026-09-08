import 'package:flutter/material.dart';
import '../../../../config/theme.dart';
import '../../../../core/models/trip_state.dart';
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
            content: Text('Couldn\'t save that. Check your connection and '
                'try again.'),
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

        if (state.trip.isTerminal && !_finishedNotified) {
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
    // Payment takes precedence once the driver is with the passenger: the
    // trip cannot move on until it is settled.
    if (s.trip == TripStatus.driverArrived) {
      switch (s.payment) {
        case PaymentState.unpaid:
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
          return [
            _waitingNote('Waiting for the passenger to pay again.'),
          ];
        case PaymentState.paymentConfirmed:
          break; // handled by the trip-status switch below
      }
    }

    switch (s.trip) {
      case TripStatus.requested:
        return [
          _primary(
            icon: Icons.check_circle_outline,
            label: 'Accept Ride',
            onPressed: () => _run(
              () => TripService.instance.moveTrip(
                bookingId: widget.bookingId,
                to: TripStatus.driverAccepted,
                by: TripRole.driver,
              ),
            ),
          ),
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

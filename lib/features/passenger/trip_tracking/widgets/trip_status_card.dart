import 'package:flutter/material.dart';
import '../../../../config/theme.dart';
import '../../../../core/models/trip_state.dart';
import '../../../../core/services/fare_service.dart';
import '../../../../core/services/trip_service.dart';

/// The passenger's view of the shared trip record.
///
/// Subscribes to the same `bookings/{id}` document the driver writes to, so
/// when the driver advances the trip or confirms payment this rebuilds on its
/// own — the passenger never refreshes or reopens anything.
class TripStatusCard extends StatefulWidget {
  final String bookingId;

  /// Invoked when the passenger chooses GCash, so the host screen can push
  /// the existing payment screen.
  final Future<void> Function()? onPayWithGcash;

  const TripStatusCard({
    super.key,
    required this.bookingId,
    this.onPayWithGcash,
  });

  @override
  State<TripStatusCard> createState() => _TripStatusCardState();
}

class _TripStatusCardState extends State<TripStatusCard> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on TripTransitionException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
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
        // A dropped connection must never be read as a status change — keep
        // showing the last known state and say we're reconnecting.
        if (snapshot.hasError) {
          return _banner(
            color: AppTheme.warning,
            icon: Icons.wifi_off,
            title: 'Connection lost',
            message: 'Reconnecting… your trip is safe.',
          );
        }
        if (!snapshot.hasData) {
          return _banner(
            color: AppTheme.info,
            icon: Icons.sync,
            title: 'Syncing…',
            message: 'Getting the latest trip status.',
          );
        }

        final s = snapshot.data!;
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.lg),
          color: _tint(s),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_icon(s), color: _accent(s), size: 22),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      _headline(s),
                      style: Theme.of(
                        context,
                      ).textTheme.titleMedium?.copyWith(color: _accent(s)),
                    ),
                  ),
                ],
              ),
              if (_subtitle(s) != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  _subtitle(s)!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              ..._actionsFor(s),
            ],
          ),
        );
      },
    );
  }

  // ── state → copy ──────────────────────────────────────────────────────

  String _headline(TripState s) {
    if (s.awaitingPaymentAfterRide) return 'Pay your driver';
    if (s.trip == TripStatus.driverArrived && s.payAfterAgreed) {
      return 'Pay at the end of the ride';
    }
    if (s.trip == TripStatus.driverArrived && !s.payment.isSettled) {
      return switch (s.payment) {
        PaymentState.unpaid => 'Your driver has arrived',
        PaymentState.paymentSubmitted => 'Payment submitted',
        PaymentState.paymentVerifying => 'Verifying your payment',
        PaymentState.paymentRejected => 'Payment not verified',
        PaymentState.paymentConfirmed => 'Payment confirmed',
      };
    }
    if (s.trip == TripStatus.readyToStart) return 'Payment confirmed';
    return s.trip.passengerLabel;
  }

  String? _subtitle(TripState s) {
    if (s.awaitingPaymentAfterRide) {
      return switch (s.payment) {
        PaymentState.paymentSubmitted =>
          'Waiting for ${s.driverName ?? 'your driver'} to check it.',
        PaymentState.paymentVerifying =>
          'Your driver is checking the payment. Please wait…',
        PaymentState.paymentRejected => s.payment.passengerLabel,
        _ =>
          'Your ride is finished. Pay '
              '${FareService.instance.formatFare(s.fare)} now.',
      };
    }
    if (s.trip == TripStatus.driverArrived && s.payAfterAgreed) {
      return '${s.driverName ?? 'Your driver'} agreed. Pay '
          '${FareService.instance.formatFare(s.fare)} when you arrive.';
    }
    if (s.trip == TripStatus.driverArrived && !s.payment.isSettled) {
      return switch (s.payment) {
        PaymentState.unpaid =>
          'Pay ${FareService.instance.formatFare(s.fare)} to start your trip.',
        PaymentState.paymentSubmitted =>
          'Waiting for ${s.driverName ?? 'your driver'} to verify it.',
        PaymentState.paymentVerifying =>
          'Your driver is checking the payment. Please wait…',
        PaymentState.paymentRejected => s.payment.passengerLabel,
        PaymentState.paymentConfirmed => null,
      };
    }
    return switch (s.trip) {
      TripStatus.requested => 'Matching you with the next driver in the queue.',
      TripStatus.driverAccepted =>
        '${s.driverName ?? 'Your driver'} is preparing to head over.',
      TripStatus.driverOnTheWay => 'Watch the map to follow their approach.',
      TripStatus.readyToStart => 'Your driver will start the trip shortly.',
      TripStatus.tripInProgress => 'Enjoy your ride.',
      TripStatus.tripCompleted =>
        s.receiptNumber != null
            ? 'Receipt ${s.receiptNumber}'
            : 'Thanks for riding with us.',
      TripStatus.cancelled => 'This trip is no longer active.',
      _ => null,
    };
  }

  // ── state → actions ───────────────────────────────────────────────────

  List<Widget> _actionsFor(TripState s) {
    // Payable before the ride, as before — and now after it too, for a trip
    // the driver agreed to be paid for at the end.
    final payable =
        (s.trip == TripStatus.driverArrived ||
            s.trip == TripStatus.tripCompleted) &&
        (s.payment == PaymentState.unpaid ||
            s.payment == PaymentState.paymentRejected);

    if (!payable) return const [];

    // Waiting on the driver's answer to "pay after the ride": no buttons,
    // so the passenger cannot ask twice or pay while the ask is open.
    if (s.payAfterPending && s.trip == TripStatus.driverArrived) {
      return const [
        SizedBox(height: AppSpacing.md),
        Text(
          'Asked your driver if you can pay at the end of the ride…',
          style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
        ),
      ];
    }

    return [
      const SizedBox(height: AppSpacing.md),
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run(
                      () => TripService.instance.movePayment(
                        bookingId: widget.bookingId,
                        to: PaymentState.paymentSubmitted,
                        by: TripRole.passenger,
                        method: 'cash',
                      ),
                    ),
              icon: const Icon(Icons.payments_outlined, size: 18),
              label: const Text('Pay cash'),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _busy || widget.onPayWithGcash == null
                  ? null
                  : () => _run(() async {
                      await TripService.instance.setPaymentMethod(
                        bookingId: widget.bookingId,
                        method: 'gcash',
                      );
                      await widget.onPayWithGcash!();
                    }),
              icon: const Icon(Icons.qr_code, size: 18),
              label: const Text('GCash'),
            ),
          ),
        ],
      ),
      // Only before the ride: afterwards there is nothing left to put off.
      if (s.trip == TripStatus.driverArrived && !s.payAfterAgreed) ...[
        const SizedBox(height: AppSpacing.sm),
        TextButton.icon(
          onPressed: _busy
              ? null
              : () => _run(
                  () => TripService.instance.requestPayAfter(widget.bookingId),
                ),
          icon: const Icon(Icons.schedule, size: 18),
          label: const Text('Ask to pay after the ride'),
        ),
      ],
    ];
  }

  // ── styling ───────────────────────────────────────────────────────────

  Color _accent(TripState s) {
    if (s.trip == TripStatus.cancelled) return AppTheme.errorRed;
    if (s.payment == PaymentState.paymentRejected) return AppTheme.errorRed;
    if (s.trip == TripStatus.tripCompleted || s.payment.isSettled) {
      return AppTheme.success;
    }
    if (s.trip == TripStatus.driverArrived) return AppTheme.warning;
    return AppTheme.info;
  }

  Color _tint(TripState s) => _accent(s).withValues(alpha: 0.10);

  IconData _icon(TripState s) {
    if (s.trip == TripStatus.cancelled) return Icons.cancel_outlined;
    if (s.payment == PaymentState.paymentRejected) return Icons.error_outline;
    if (s.trip == TripStatus.driverArrived && !s.payment.isSettled) {
      return s.payment == PaymentState.paymentVerifying
          ? Icons.hourglass_top
          : Icons.payments_outlined;
    }
    return switch (s.trip) {
      TripStatus.requested => Icons.search,
      TripStatus.driverAccepted => Icons.thumb_up_alt_outlined,
      TripStatus.driverOnTheWay => Icons.directions_car_outlined,
      TripStatus.driverArrived => Icons.where_to_vote_outlined,
      TripStatus.readyToStart => Icons.check_circle_outline,
      TripStatus.tripInProgress => Icons.electric_rickshaw,
      TripStatus.tripCompleted => Icons.check_circle,
      TripStatus.cancelled => Icons.cancel_outlined,
    };
  }

  Widget _banner({
    required Color color,
    required IconData icon,
    required String title,
    required String message,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      color: color.withValues(alpha: 0.10),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(color: color),
                ),
                Text(message, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

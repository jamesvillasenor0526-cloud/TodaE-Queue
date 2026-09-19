import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import '../../../widgets/map_tiles.dart';
import 'package:latlong2/latlong.dart';
import '../../../config/routes.dart';
import '../../../config/theme.dart';
import '../../../core/models/location_need.dart';
import '../../../core/services/fare_service.dart';
import '../../../core/services/geofence_service.dart';
import '../../../core/services/location_hub.dart';
import '../../../core/services/dispatch_service.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/utils/date_formatter.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../../../core/services/cloudinary_service.dart';
import '../../../config/theme_controller.dart';
import '../../../widgets/shimmer_loading.dart';
import '../../../widgets/state_views.dart';
import 'widgets/trip_action_panel.dart';
import '../../../core/models/trip_state.dart';
import '../../../core/models/navigation_state.dart';
import '../../../core/services/trip_service.dart';
import '../../../core/models/road_report.dart';
import '../../shared/reports/report_map_layer.dart';
import '../../shared/reports/report_sheet.dart';
import '../navigation/navigation_panel.dart';
import '../../shared/navigation/gliding_marker_layer.dart';
import '../../shared/navigation/trip_route_layer.dart';
import '../../shared/navigation/vehicle_position.dart';
import '../../shared/chat/message_button.dart';
import '../../shared/reports/my_reports_screen.dart';
import '../../shared/sos/sos_button.dart';
import '../../../core/models/trip_message.dart';
import '../../../core/models/queue_rules.dart';
import '../../../core/services/contact_service.dart';
import '../../shared/profile/my_contact.dart';
import '../../../core/services/phone_actions.dart';
import '../../../core/services/rating_service.dart';

class DriverHomeScreen extends StatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> {
  final uid = FirebaseAuth.instance.currentUser!.uid;
  final _geofence = GeofenceService.instance;
  int _currentIndex = 0;

  StreamSubscription<Position>? _positionSub;
  StreamSubscription<QuerySnapshot>? _activeBookingSub;
  bool _isCheckingLocation = false;

  /// Location writes are at most this frequent; see _onPositionUpdate.
  static const Duration _locationPushEvery = Duration(seconds: 2);
  DateTime? _lastLocationPush;
  Position? _heldPosition;
  Position? _lastPosition;
  Timer? _pushTimer;
  Timer? _heartbeat;
  static const Duration _tripHeartbeatEvery = Duration(seconds: 20);
  bool _locationPermissionDenied = false;
  String? _lastPromptedTerminalId;
  bool _hasActiveEntry = false;
  String? _activeBookingId;

  /// The terminal this driver is assigned to, read once instead of on every
  /// GPS reading — which, at a reading every two seconds, was thousands of
  /// database reads a day per driver for a value that rarely changes.
  String? _assignedTerminalId;
  bool _profileLoaded = false;

  /// The queue entry this driver is waiting in, and the terminal's boundary,
  /// so leaving the terminal can give up the place. See _watchMyQueue.
  String? _waitingEntryId;
  String? _waitingTerminalName;
  List<LatLng>? _waitingBoundary;
  int _readingsOutside = 0;
  bool _leavingQueue = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _startLocationWatch();
    _watchActiveBooking();
    WidgetsBinding.instance.addObserver(_lifecycle);
    _setOnline(true);
    // Passengers cannot write a driver's profile, so the rating they leave
    // never reached this driver's average. Their own app keeps it in step.
    RatingService.instance.syncMyAverage();
  }

  @override
  void dispose() {
    _activeBookingSub?.cancel();
    _profileSub?.cancel();
    _positionSub?.cancel();
    _pushTimer?.cancel();
    _heartbeat?.cancel();
    WidgetsBinding.instance.removeObserver(_lifecycle);
    RatingService.instance.stop();
    _setOnline(false);
    _geofence.stopTracking();
    super.dispose();
  }

  /// Marks this driver online or offline for the dashboard.
  ///
  /// Nothing ever set it back to false: 25 drivers showed as online, most of
  /// them silent for weeks, so the dashboard's queue and map were full of
  /// drivers who were not there. Closing the app, switching away from it and
  /// signing out all now say so.
  void _setOnline(bool online) {
    FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .update({
          'isOnline': online,
          if (online) 'lastOnlineAt': FieldValue.serverTimestamp(),
          if (!online) 'wentOfflineAt': FieldValue.serverTimestamp(),
        })
        .catchError((Object e) => debugPrint('Could not set online: $e'));
  }

  late final _lifecycle = _LifecycleWatcher(
    onHidden: () => _setOnline(false),
    onShown: () => _setOnline(true),
  );

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _profileSub;
  bool _disabledShown = false;

  /// Follows the driver's own profile rather than reading it once, so what
  /// an admin changes from the dashboard applies while the app is open: a
  /// new assigned terminal is used for the very next check-in, and a
  /// disabled account is signed out rather than left driving until the app
  /// happens to restart.
  void _loadProfile() {
    _profileSub = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots()
        .listen((doc) {
          if (!mounted) return;
          final data = doc.data();
          if (data?['isActive'] == false) {
            _onDisabled();
            return;
          }
          setState(() {
            _assignedTerminalId = data?['assignedTerminalId'] as String?;
            _profileLoaded = true;
          });
        }, onError: (Object e) => debugPrint('Driver profile: $e'));
  }

  Future<void> _onDisabled() async {
    if (_disabledShown) return;
    _disabledShown = true;
    _setOnline(false);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Account disabled'),
        content: const Text(
          'Your TODA admin has disabled this account. You have been taken '
          'out of the queue. Contact them to have it turned back on.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, AppRoutes.login, (_) => false);
  }

  void _watchActiveBooking() {
    _activeBookingSub = FirebaseFirestore.instance
        .collection('queueEntries')
        .where('driverId', isEqualTo: uid)
        .where('status', whereIn: ['waiting', 'dispatched', 'accepted'])
        .snapshots()
        .listen((snapshot) {
          final docs = snapshot.docs;
          final onTrip = docs
              .where(
                (d) => const [
                  'dispatched',
                  'accepted',
                ].contains(d.data()['status']),
              )
              .firstOrNull;
          if (onTrip != null) {
            final bookingId = onTrip.data()['bookingId'] as String?;
            if (bookingId != null && bookingId != _activeBookingId) {
              setState(() {
                _activeBookingId = bookingId;
                _hasActiveEntry = true;
              });
            }
          }

          // Waiting in the queue: watched so that driving away gives up the
          // place, instead of holding the front of a queue from elsewhere.
          final waiting = docs
              .where((d) => d.data()['status'] == 'waiting')
              .firstOrNull;
          final entryId = waiting?.id;
          if (entryId != _waitingEntryId) {
            _readingsOutside = 0;
            _waitingBoundary = null;
            _waitingTerminalName = waiting?.data()['terminalName'] as String?;
            setState(() => _waitingEntryId = entryId);
            final terminalId = waiting?.data()['terminalId'] as String?;
            if (terminalId != null) _loadWaitingBoundary(terminalId);
          }
        }, onError: _listenerError);
  }

  /// A live query that fails — most often permission-denied in the moment
  /// between signing out and this screen closing — must not surface as an
  /// unhandled exception; the next sign-in opens fresh listeners.
  static void _listenerError(Object e) =>
      debugPrint('Driver home listener stopped: $e');

  Future<void> _startLocationWatch() async {
    final started = await _geofence.startTracking();
    if (!started) {
      if (mounted) setState(() => _locationPermissionDenied = true);
      return;
    }
    _positionSub = _geofence.positionStream.listen(_onPositionUpdate);
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(_tripHeartbeatEvery, (_) => _tripHeartbeat());
  }

  Future<void> _loadWaitingBoundary(String terminalId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('terminals')
          .doc(terminalId)
          .get();
      final raw = doc.data()?['boundary'] as List<dynamic>? ?? [];
      final points = [
        for (final p in raw)
          if (_geofence.parseBoundaryPoint(p) case final LatLng at) at,
      ];
      if (mounted && _waitingEntryId != null) {
        setState(() => _waitingBoundary = points);
      }
    } catch (e) {
      // No boundary, no ejection: the place is kept.
      debugPrint('Could not read the terminal boundary: $e');
    }
  }

  /// Gives up the queue place once the driver has really left the terminal.
  ///
  /// Checking in used to be the last time position mattered, so a driver
  /// could check in, drive across town, and still be sent the next passenger
  /// from a terminal they were nowhere near. Needs [kQueueExitFixes] readings
  /// beyond [kQueueExitMeters] outside, so drift at the edge costs nobody
  /// their turn.
  Future<void> _checkStillAtTerminal(Position position) async {
    final entryId = _waitingEntryId;
    final boundary = _waitingBoundary;
    if (entryId == null || boundary == null || _leavingQueue) return;

    final outside = metersOutsideBoundary(
      LatLng(position.latitude, position.longitude),
      boundary,
    );
    if (outside == 0) {
      _readingsOutside = 0;
      return;
    }
    _readingsOutside++;
    if (!leavesQueue(
      metersOutside: outside,
      consecutiveOutside: _readingsOutside,
    )) {
      return;
    }

    _leavingQueue = true;
    final terminal = _waitingTerminalName ?? 'the terminal';
    try {
      // Re-read inside a transaction and give up the place only if the
      // entry is still waiting.
      //
      // Whether the driver is waiting is decided here from local state,
      // which can be a few seconds behind — and the same account signed in
      // on a second device has its own idea of where the driver is. Without
      // this check, a driver dispatched a moment ago was removed from the
      // queue for "leaving the terminal", which is exactly what a driver on
      // their way to a passenger is supposed to do. It happened: a booking
      // was left REQUESTED against a cancelled entry, and the trip never
      // appeared on the driver's screen.
      final left = await FirebaseFirestore.instance.runTransaction<bool>((
        tx,
      ) async {
        final ref = FirebaseFirestore.instance
            .collection('queueEntries')
            .doc(entryId);
        final snap = await tx.get(ref);
        if (!mayGiveUpPlace(snap.data()?['status'] as String?)) return false;
        tx.update(ref, {
          'status': 'cancelled',
          'cancelledAt': FieldValue.serverTimestamp(),
          'cancelledReason': 'Left the terminal',
          'completedAt': FieldValue.serverTimestamp(),
        });
        return true;
      });
      if (!left) {
        // Dispatched in the meantime: they have a passenger, not a lost
        // place. Say nothing and let the trip screen take over.
        _readingsOutside = 0;
        return;
      }
      // No cooldown: they have not abandoned a passenger, and driving back
      // should let them check in again straight away.
      _readingsOutside = 0;
      _lastPromptedTerminalId = null;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'You left $terminal, so you are out of the queue. '
              'Check in again when you return.',
            ),
            backgroundColor: AppTheme.warning,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      debugPrint('Could not leave the queue automatically: $e');
    } finally {
      _leavingQueue = false;
    }
  }

  /// Sends the driver's position for the maps others watch.
  ///
  /// The stream reports every 3 m, which while driving can be several times
  /// a second. Maps glide between readings, so one every couple of seconds
  /// looks the same to anyone watching and costs a fraction of the writes.
  /// A reading that arrives too soon is held, not dropped: the last one
  /// before the tricycle stops is where it actually stopped, and the stream
  /// sends nothing more until it moves again.
  void _pushLocation(Position position) {
    _lastPosition = position;
    _heldPosition = position;
    if (_pushTimer?.isActive ?? false) return; // the held one goes shortly
    final last = _lastLocationPush;
    final wait = last == null
        ? Duration.zero
        : _locationPushEvery - DateTime.now().difference(last);
    _pushTimer = Timer(wait.isNegative ? Duration.zero : wait, () {
      final p = _heldPosition;
      _heldPosition = null;
      if (p == null || !mounted) return;
      _lastLocationPush = DateTime.now();
      _writeLocation(p);
    });
  }

  /// During a trip, re-sends the position while the tricycle is standing
  /// still — waiting at the pickup, stopped in traffic. The stream reports
  /// only movement, so otherwise the passenger's "updated N s ago" would
  /// climb and they would be told the phone may have lost signal while the
  /// driver sat outside their door. Only during a trip: every driver in a
  /// queue doing this would cost thousands of writes a day for nothing.
  void _tripHeartbeat() {
    final p = _lastPosition;
    final last = _lastLocationPush;
    if (_activeBookingId == null || p == null || !mounted) return;
    // A little under the period, so a send just before the tick does not
    // push the next one a whole period later.
    if (last != null &&
        DateTime.now().difference(last) <
            _tripHeartbeatEvery - const Duration(seconds: 5)) {
      return; // moving, so already sending
    }
    _lastLocationPush = DateTime.now();
    _writeLocation(p);
  }

  Future<void> _writeLocation(Position position) async {
    try {
      // Update driver's live location in users collection
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'lastLatitude': position.latitude,
        'lastLongitude': position.longitude,
        'lastLocationAt': FieldValue.serverTimestamp(),
        'isOnline': true,
      });

      // Update driver location in active booking if dispatched
      if (_activeBookingId != null) {
        await FirebaseFirestore.instance
            .collection('bookings')
            .doc(_activeBookingId)
            .set({
              'driverLatitude': position.latitude,
              'driverLongitude': position.longitude,
              // So the passenger can tell a live position from one a
              // phone stopped sending minutes ago.
              'driverLocationAt': FieldValue.serverTimestamp(),
              // How fast and which way, so the passenger's map can carry
              // the tricycle along the road between these updates instead
              // of dragging it from one two-second-old dot to the next.
              'driverSpeed': position.speed.isFinite && position.speed > 0
                  ? position.speed
                  : 0,
              'driverHeading': position.heading.isFinite
                  ? position.heading
                  : null,
            }, SetOptions(merge: true));
      }
    } catch (e) {
      // The next reading carries the same information.
      debugPrint('Could not send driver location: $e');
    }
  }

  Future<void> _onPositionUpdate(Position position) async {
    debugPrint('📍 GPS STREAM: ${position.latitude}, ${position.longitude}');
    debugPrint(
      '📍 _hasActiveEntry=$_hasActiveEntry, _activeBookingId=$_activeBookingId',
    );

    _pushLocation(position);
    await _checkStillAtTerminal(position);

    if (_hasActiveEntry || _isCheckingLocation || !mounted) return;

    _isCheckingLocation = true;
    try {
      final point = LatLng(position.latitude, position.longitude);

      // Read once at start-up, not on every reading.
      if (!_profileLoaded) return;
      final assignedTerminalId = _assignedTerminalId;

      // No assigned terminal — skip
      if (assignedTerminalId == null) return;

      final terminalDoc = await _geofence.findTerminalAtPoint(point);

      if (terminalDoc == null) {
        // Driver left all terminals — reset
        if (_lastPromptedTerminalId != null) {
          setState(() => _lastPromptedTerminalId = null);
          if (mounted) {
            Navigator.of(
              context,
            ).popUntil((r) => r.isFirst || r is! PopupRoute);
          }
        }
        return;
      }

      // Only prompt for assigned terminal — ignore others
      if (terminalDoc.id != assignedTerminalId) return;

      if (terminalDoc.id != _lastPromptedTerminalId && mounted) {
        _lastPromptedTerminalId = terminalDoc.id;
        _showArrivalPrompt(terminalDoc);
      }
    } finally {
      _isCheckingLocation = false;
    }
  }

  void _showArrivalPrompt(
    QueryDocumentSnapshot<Map<String, dynamic>> terminalDoc,
  ) async {
    final data = terminalDoc.data();
    final name = data['name'] ?? 'this terminal';

    // Check if driver is verified before showing prompt
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .get();
    final userData = userDoc.data();
    final isVerified = userData?['isVerified'] ?? false;

    if (!isVerified) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('You need to be verified before joining the queue.'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
      return;
    }

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isDismissible: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.location_on,
                  color: AppTheme.primaryGreen,
                  size: 28,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "You've arrived at $name",
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Would you like to check in to the queue here?',
              style: TextStyle(color: AppTheme.textMuted),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      Navigator.pop(context);
                      setState(() => _lastPromptedTerminalId = null);
                    },
                    child: const Text('Not now'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      Navigator.pop(context);
                      await _checkIn(terminalDoc.id, name);
                    },
                    child: const Text('Check In'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _checkIn(String terminalId, String terminalName) async {
    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();

      final data = userDoc.data();
      final driverName = (data?['name'] ?? 'Driver').toString();
      final assignedTerminalId = data?['assignedTerminalId'];
      final isVerified = data?['isVerified'] ?? false;
      final verificationStatus = data?['verificationStatus'] ?? 'pending';

      // Block unverified drivers
      if (!isVerified) {
        String message;
        switch (verificationStatus) {
          case 'pending':
            message =
                'Your account is pending verification. Please wait for admin approval.';
            break;
          case 'rejected':
            message =
                'Your account was rejected. Please contact your TODA admin.';
            break;
          default:
            message =
                'Your account is not verified. Please contact your TODA admin.';
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              backgroundColor: AppTheme.warning,
              duration: const Duration(seconds: 4),
            ),
          );
        }
        return;
      }

      // Check cooldown
      final cooldownUntil = data?['queueCooldownUntil'] as Timestamp?;
      if (cooldownUntil != null) {
        final cooldownEnd = cooldownUntil.toDate().add(
          const Duration(minutes: 20),
        );
        final now = DateTime.now();
        if (now.isBefore(cooldownEnd)) {
          final remaining = cooldownEnd.difference(now);
          final minutesLeft = remaining.inMinutes + 1;
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Cooldown active. You can re-join in $minutesLeft minute(s).',
                ),
                backgroundColor: AppTheme.warning,
                duration: const Duration(seconds: 4),
              ),
            );
          }
          return;
        }
      }

      // Block check-in if driver has active booking
      final activeBookingSnap = await FirebaseFirestore.instance
          .collection('queueEntries')
          .where('driverId', isEqualTo: uid)
          .where('status', whereIn: ['dispatched', 'accepted'])
          .limit(1)
          .get();

      if (activeBookingSnap.docs.isNotEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('You have an active booking. Complete it first.'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
        return;
      }

      // Block check-in at wrong terminal
      if (assignedTerminalId != null && assignedTerminalId != terminalId) {
        final assignedTerminalName =
            data?['assignedTerminalName'] ?? 'your assigned terminal';
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('You can only check in at $assignedTerminalName.'),
              backgroundColor: AppTheme.errorRed,
            ),
          );
        }
        return;
      }

      await FirebaseFirestore.instance.collection('queueEntries').add({
        'driverId': uid,
        'driverName': driverName,
        'terminalId': terminalId,
        'terminalName': terminalName,
        'status': 'waiting',
        'checkedInAt': FieldValue.serverTimestamp(),
      });

      // Clear cooldown on successful check-in
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'queueCooldownUntil': FieldValue.delete(),
      });

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Checked in at $terminalName')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Check-in failed: $e')));
      }
    }
  }

  Future<void> _leaveQueue(String entryId) async {
    await FirebaseFirestore.instance
        .collection('queueEntries')
        .doc(entryId)
        .update({
          'status': 'cancelled',
          'cancelledAt': FieldValue.serverTimestamp(),
          'cancelledReason': 'Driver left the queue',
          'completedAt': FieldValue.serverTimestamp(),
        });

    // Save cooldown timestamp to the USER document
    await FirebaseFirestore.instance.collection('users').doc(uid).update({
      'queueCooldownUntil': FieldValue.serverTimestamp(),
    });

    _lastPromptedTerminalId = null;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You left the queue. 20-minute cooldown applied.'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _completeTrip(String entryId, String? bookingId) async {
    await DispatchService.instance.completeTrip(
      queueEntryId: entryId,
      bookingId: bookingId,
    );
    setState(() {
      _activeBookingId = null;
      _hasActiveEntry = false;
      _lastPromptedTerminalId = null;
      _isCheckingLocation = false;
    });

    // Restart GPS stream for next check-in
    await _startLocationWatch();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Trip completed. You can check in again.'),
        ),
      );
    }
  }

  // These asked canLaunchUrl first, which on Android 11+ said no without the
  // manifest declaring the dialer and SMS app, so the buttons did nothing.
  // See phone_actions.dart.
  void _callPassenger(String phoneNumber) =>
      callNumber(context, phoneNumber, who: 'The passenger');

  void _messagePassenger(String phoneNumber) =>
      textNumber(context, phoneNumber, who: 'The passenger');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TODA E-QUEUE+'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Sign Out'),
                  content: const Text('Are you sure you want to sign out?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text(
                        'Sign Out',
                        style: TextStyle(color: AppTheme.errorRed),
                      ),
                    ),
                  ],
                ),
              );
              if (confirm == true && context.mounted) {
                await FirebaseAuth.instance.signOut();
                if (!context.mounted) return;
                Navigator.pushReplacementNamed(context, AppRoutes.login);
              }
            },
          ),
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          _QueueTab(
            uid: uid,
            locationPermissionDenied: _locationPermissionDenied,
            hasActiveEntry: _hasActiveEntry,
            activeBookingId: _activeBookingId,
            onActiveEntryChanged: (isActive, bookingId) {
              if (isActive != _hasActiveEntry ||
                  bookingId != _activeBookingId) {
                setState(() {
                  _hasActiveEntry = isActive;
                  _activeBookingId = bookingId;
                });
              }
            },
            onLeaveQueue: _leaveQueue,
            onCompleteTrip: _completeTrip,
            onBookingAccepted: _startLocationWatch, // ADD THIS
            onCallPassenger: _callPassenger, // ← ADD
            onMessagePassenger: _messagePassenger, // ← ADD
          ),
          _DriverMapTab(isActive: _currentIndex == 1),
          _DriverHistoryTab(uid: uid),
          _DriverProfileTab(uid: uid),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.electric_rickshaw_outlined),
            selectedIcon: Icon(Icons.electric_rickshaw),
            label: 'Queue',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Map',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outlined),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
      floatingActionButton: const SosButton(),
    );
  }
}

// ─── Queue Tab ───────────────────────────────────────────────────────────────

class _QueueTab extends StatelessWidget {
  final String uid;
  final bool locationPermissionDenied;
  final bool hasActiveEntry;
  final String? activeBookingId;
  final Function(bool, String?) onActiveEntryChanged;
  final Function(String) onLeaveQueue;
  final Function(String, String?) onCompleteTrip;
  final VoidCallback onBookingAccepted;
  final Function(String) onCallPassenger; // ← ADD
  final Function(String) onMessagePassenger; // ← ADD

  const _QueueTab({
    required this.uid,
    required this.locationPermissionDenied,
    required this.hasActiveEntry,
    required this.activeBookingId,
    required this.onActiveEntryChanged,
    required this.onLeaveQueue,
    required this.onCompleteTrip,
    required this.onBookingAccepted,
    required this.onCallPassenger, // ← ADD
    required this.onMessagePassenger, // ← ADD
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance.collection('users').doc(uid).get(),
      builder: (context, userSnapshot) {
        final fullName = userSnapshot.data?['name'] ?? 'Driver';
        final firstName = fullName.toString().split(' ').first;

        return Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              color: AppTheme.primaryGreen,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Hello, $firstName! 🚖',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    locationPermissionDenied
                        ? 'Location is off — enable it to check in automatically.'
                        : "We'll let you know when you arrive at a terminal.",
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),

                  // ─── ADD THIS: Cooldown warning ───
                  FutureBuilder<DocumentSnapshot>(
                    future: FirebaseFirestore.instance
                        .collection('users')
                        .doc(uid)
                        .get(),
                    builder: (context, userSnap) {
                      if (!userSnap.hasData || userSnap.data == null) {
                        return const SizedBox.shrink();
                      }

                      final userData =
                          userSnap.data!.data() as Map<String, dynamic>?;
                      if (userData == null) return const SizedBox.shrink();

                      final cooldownUntil =
                          userData['queueCooldownUntil'] as Timestamp?;

                      if (cooldownUntil == null) return const SizedBox.shrink();

                      final cooldownEnd = cooldownUntil.toDate().add(
                        const Duration(minutes: 20),
                      );
                      final now = DateTime.now();
                      if (now.isAfter(cooldownEnd)) {
                        return const SizedBox.shrink();
                      }

                      final remaining = cooldownEnd.difference(now);
                      final minutesLeft = remaining.inMinutes + 1;

                      return Container(
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.orange.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.timer,
                              color: AppTheme.warning,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Cooldown: You can re-join in $minutesLeft minute(s)',
                                style: const TextStyle(
                                  color: AppTheme.warning,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('queueEntries')
                    .where('driverId', isEqualTo: uid)
                    .where(
                      'status',
                      whereIn: ['waiting', 'dispatched', 'accepted'],
                    )
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(child: Text('Error: ${snapshot.error}'));
                  }

                  final entries = snapshot.data?.docs ?? [];
                  // A trip outranks a place in the queue. Taking whichever
                  // entry came back first meant a leftover 'waiting' entry
                  // could hide the trip the driver had just been given.
                  final activeEntry =
                      entries
                          .where(
                            (d) => const ['dispatched', 'accepted'].contains(
                              (d.data() as Map<String, dynamic>)['status'],
                            ),
                          )
                          .firstOrNull ??
                      entries.firstOrNull;
                  final activeData =
                      activeEntry?.data() as Map<String, dynamic>?;
                  final isDispatched = activeData?['status'] == 'dispatched';
                  final isAccepted = activeData?['status'] == 'accepted';
                  final bookingId = activeData?['bookingId'] as String?;

                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    debugPrint(
                      '📋 Queue entry: status=${activeData?['status']}, bookingId=$bookingId',
                    );
                    onActiveEntryChanged(
                      activeEntry != null,
                      (isDispatched || isAccepted) ? bookingId : null,
                    );
                    if (isDispatched && bookingId != null) {
                      NotificationService.instance.showDispatchNotification(
                        driverName: activeData?['driverName'] ?? 'Driver',
                        terminalName: activeData?['terminalName'] ?? 'Terminal',
                      );
                    }
                  });

                  if (activeEntry == null) {
                    return _NoQueueView(isWatching: !locationPermissionDenied);
                  }

                  return _ActiveQueueView(
                    entry: activeEntry,
                    onLeaveQueue: () => onLeaveQueue(activeEntry.id),
                    onCompleteTrip: () {
                      final data = activeEntry.data() as Map<String, dynamic>;
                      onCompleteTrip(
                        activeEntry.id,
                        data['bookingId'] as String?,
                      );
                    },
                    onBookingAccepted:
                        onBookingAccepted, // ADD THIS - pass it through
                    onCallPassenger: onCallPassenger, // ← ADD
                    onMessagePassenger: onMessagePassenger, // ← ADD
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─── No Queue View ────────────────────────────────────────────────────────────

class _NoQueueView extends StatelessWidget {
  final bool isWatching;
  const _NoQueueView({required this.isWatching});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isWatching ? Icons.my_location : Icons.location_off,
              size: 64,
              color: AppTheme.textMuted,
            ),
            const SizedBox(height: 16),
            Text(
              isWatching
                  ? "You're not in a queue yet.\nDrive to a terminal — we'll let you know when you arrive."
                  : 'Location is off.\nEnable it in Settings to auto check-in.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Active Queue View ────────────────────────────────────────────────────────

class _ActiveQueueView extends StatefulWidget {
  final QueryDocumentSnapshot entry;
  final VoidCallback onLeaveQueue;
  final VoidCallback onCompleteTrip;
  final VoidCallback onBookingAccepted;
  final Function(String) onCallPassenger; // ← ADD
  final Function(String) onMessagePassenger; // ← ADD

  const _ActiveQueueView({
    required this.entry,
    required this.onLeaveQueue,
    required this.onCompleteTrip,
    required this.onBookingAccepted,
    required this.onCallPassenger, // ← ADD
    required this.onMessagePassenger, // ← ADD
  });

  @override
  State<_ActiveQueueView> createState() => _ActiveQueueViewState();
}

class _ActiveQueueViewState extends State<_ActiveQueueView> {
  bool _isAccepting = false;
  bool _isHighlightingDestination = false;

  Future<void> _acceptBooking(
    BuildContext context,
    Map<String, dynamic> data,
  ) async {
    if (_isAccepting) return;
    _isAccepting = true;

    final bookingId = data['bookingId'] as String?;
    final queueEntryId = widget.entry.id;
    if (bookingId == null) {
      _isAccepting = false;
      return;
    }

    try {
      // Route the booking through the state machine so the transition is
      // validated and the passenger's screen picks it up straight away.
      await TripService.instance.moveTrip(
        bookingId: bookingId,
        to: TripStatus.driverAccepted,
        by: TripRole.driver,
      );
      // The queue entry is this driver's own bookkeeping, not shared state.
      await FirebaseFirestore.instance
          .collection('queueEntries')
          .doc(queueEntryId)
          .update({
            'status': 'accepted',
            'acceptedAt': FieldValue.serverTimestamp(),
          });
      HapticFeedback.mediumImpact();

      widget.onBookingAccepted();

      if (!context.mounted) {
        _isAccepting = false;
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Booking accepted!'),
          backgroundColor: AppTheme.success,
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e is TripTransitionException
                  ? e.message
                  : 'Couldn\'t accept the booking. Check your connection and '
                        'try again.',
            ),
            backgroundColor: AppTheme.errorRed,
          ),
        );
      }
    }
    _isAccepting = false;
  }

  Widget _fareRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.entry.data() as Map<String, dynamic>? ?? {};
    final terminalId = data['terminalId'] ?? '';
    final terminalName = data['terminalName'] ?? 'Terminal';
    final status = data['status'] ?? 'waiting';
    final checkedInAt = data['checkedInAt'] as Timestamp?;

    String waitingDuration = 'Just now';
    if (checkedInAt != null) {
      final duration = DateTime.now().difference(checkedInAt.toDate());
      if (duration.inHours > 0) {
        waitingDuration = '${duration.inHours}h ${duration.inMinutes % 60}m';
      } else if (duration.inMinutes > 0) {
        waitingDuration = '${duration.inMinutes}m';
      }
    }

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('queueEntries')
          .where('terminalId', isEqualTo: terminalId)
          .where('status', whereIn: ['waiting', 'accepted'])
          .orderBy('checkedInAt')
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Queue error:\n${snapshot.error}',
              style: const TextStyle(color: AppTheme.errorRed),
            ),
          );
        }
        final waitingDocs = snapshot.data?.docs ?? [];
        final position =
            waitingDocs.indexWhere((d) => d.id == widget.entry.id) + 1;
        final total = waitingDocs.length;
        final driversAhead = position > 0 ? position - 1 : 0;
        final estimatedMinutes = driversAhead * 10;
        String estimatedWait = '';
        if (estimatedMinutes >= 60) {
          estimatedWait =
              '~${estimatedMinutes ~/ 60}h ${estimatedMinutes % 60}m';
        } else if (estimatedMinutes > 0) {
          estimatedWait = '~$estimatedMinutes min';
        } else {
          estimatedWait = "You're next! 🎉";
        }
        String nextDriver = 'You';
        if (position == 1) {
          nextDriver = 'You are next! 🎯';
        } else if (waitingDocs.isNotEmpty) {
          final d = waitingDocs.first.data() as Map<String, dynamic>? ?? {};
          nextDriver = '${d['driverName'] ?? 'Driver'} is next';
        }

        return Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              children: [
                Card(
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        Text(
                          terminalName,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Joined $waitingDuration ago',
                          style: const TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 20),

                        if (status == 'dispatched') ...[
                          const Icon(
                            Icons.electric_rickshaw,
                            color: AppTheme.primaryGreen,
                            size: 48,
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            "You've been dispatched!",
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.primaryGreen,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Accept the booking to see pickup location.',
                            style: TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () => _acceptBooking(context, data),
                              icon: const Icon(
                                Icons.check_circle,
                                color: Colors.white,
                              ),
                              label: const Text(
                                'Accept Booking',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.success,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                        ],

                        if (status == 'accepted') ...[
                          // The legacy `status` field collapses five trip
                          // states into 'accepted', so it cannot say where
                          // the driver is actually going. Reading tripStatus
                          // keeps this heading honest — it used to insist
                          // "navigate to the pickup location" while the map
                          // and the navigation panel were both routing to
                          // the destination.
                          _AcceptedTripHeading(
                            bookingId: data['bookingId'] as String? ?? '',
                          ),
                          const SizedBox(height: 16),

                          // Who is being picked up, and a way to reach them,
                          // first: it is what a driver looks for when the
                          // passenger is not at the pickup. It used to sit at
                          // the very bottom, below the fare, map and buttons.
                          _PassengerCard(
                            passengerId: data['passengerId'] as String?,
                            bookingId: data['bookingId'] as String? ?? '',
                            onCall: widget.onCallPassenger,
                            onMessage: widget.onMessagePassenger,
                          ),
                          const SizedBox(height: 16),

                          // Everything in a StreamBuilder for live updates
                          StreamBuilder<DocumentSnapshot>(
                            stream: FirebaseFirestore.instance
                                .collection('bookings')
                                .doc(data['bookingId'] as String? ?? '')
                                .snapshots(),
                            builder: (context, bookingSnap) {
                              if (!bookingSnap.hasData) {
                                return const SizedBox.shrink();
                              }

                              final bookingData =
                                  bookingSnap.data!.data()
                                      as Map<String, dynamic>?;
                              final distance =
                                  bookingData?['distance'] as num? ?? 0;
                              final fare = bookingData?['fare'] as num? ?? 0;
                              // The authoritative payment state, not the
                              // legacy mirror it can drift from.
                              final paymentStatus =
                                  TripState.fromMap(
                                        '',
                                        bookingData ?? const {},
                                      ).payment ==
                                      PaymentState.paymentConfirmed
                                  ? 'paid'
                                  : 'pending';
                              final paymentMethod =
                                  bookingData?['paymentMethod'] ?? 'cash';

                              return Column(
                                children: [
                                  // Fare details
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: AppTheme.primaryBlue.withValues(
                                        alpha: 0.05,
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: AppTheme.primaryBlue.withValues(
                                          alpha: 0.2,
                                        ),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          '💰 FARE DETAILS',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: AppTheme.primaryBlue,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        _fareRow(
                                          'Distance',
                                          '${distance.toStringAsFixed(2)} km',
                                        ),
                                        const SizedBox(height: 4),
                                        _fareRow(
                                          'Fare',
                                          '₱${fare.toStringAsFixed(0)}',
                                        ),
                                        const Divider(height: 12),
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            const Text(
                                              'Total to Receive',
                                              style: TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            Text(
                                              '₱${fare.toStringAsFixed(0)}',
                                              style: const TextStyle(
                                                fontSize: 18,
                                                fontWeight: FontWeight.bold,
                                                color: AppTheme.primaryGreen,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Row(
                                          children: [
                                            Icon(
                                              paymentStatus == 'paid'
                                                  ? Icons.check_circle
                                                  : Icons.schedule,
                                              color: paymentStatus == 'paid'
                                                  ? AppTheme.success
                                                  : AppTheme.textMuted,
                                              size: 16,
                                            ),
                                            const SizedBox(width: 6),
                                            Expanded(
                                              child: Text(
                                                paymentStatus == 'paid'
                                                    ? '✅ Passenger paid: ₱${fare.toStringAsFixed(0)} via ${paymentMethod == 'gcash' ? 'GCash' : 'Cash'}'
                                                    : 'Payment due after the trip ends',
                                                style: TextStyle(
                                                  color: paymentStatus == 'paid'
                                                      ? AppTheme.success
                                                      : AppTheme.textMuted,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 12),

                                  // One button, shown only once the driver
                                  // has reached the passenger. Before that
                                  // there is nothing to choose: the route is
                                  // to the pickup. After the trip starts the
                                  // destination is shown automatically.
                                  if (data['bookingId'] != null)
                                    _DestinationSwitch(
                                      bookingId: data['bookingId'] as String,
                                      showingDestination:
                                          _isHighlightingDestination,
                                      onChanged: (v) => setState(
                                        () => _isHighlightingDestination = v,
                                      ),
                                    ),

                                  const SizedBox(height: 12),

                                  MiniMapWidget(
                                    bookingId: data['bookingId'] as String?,
                                    highlightDestination:
                                        _isHighlightingDestination,
                                  ),
                                  const SizedBox(height: 12),
                                  // Live navigation: ETA, next turn, hazards
                                  // ahead, automatic rerouting, and one-tap
                                  // reporting.
                                  if (data['bookingId'] != null)
                                    NavigationPanelFor(
                                      bookingId: data['bookingId'] as String,
                                    ),
                                  const SizedBox(height: 16),
                                  // Every driver action for this trip comes
                                  // from the shared backend state, so only
                                  // the one valid next step is ever offered.
                                  if (data['bookingId'] != null)
                                    TripActionPanel(
                                      bookingId: data['bookingId'] as String,
                                      onTripFinished: widget.onCompleteTrip,
                                    ),
                                ],
                              );
                            },
                          ),
                        ],

                        if (status == 'waiting') ...[
                          Text(
                            position > 0 ? '#$position' : '—',
                            style: const TextStyle(
                              fontSize: 56,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.primaryGreen,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'of $total in queue',
                            style: const TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 12),
                          if (total > 1)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: position > 0
                                    ? (total - position + 1) / total
                                    : 0,
                                backgroundColor: Colors.grey.shade200,
                                color: AppTheme.primaryGreen,
                                minHeight: 6,
                              ),
                            ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: estimatedMinutes > 0
                                  ? Colors.blue.withValues(alpha: 0.1)
                                  : Colors.green.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.timer_outlined,
                                  size: 18,
                                  color: estimatedMinutes > 0
                                      ? AppTheme.info
                                      : AppTheme.success,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  estimatedWait,
                                  style: TextStyle(
                                    color: estimatedMinutes > 0
                                        ? AppTheme.info
                                        : AppTheme.success,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            nextDriver,
                            style: TextStyle(
                              color: position == 1
                                  ? AppTheme.success
                                  : Colors.grey.shade600,
                              fontSize: 12,
                              fontWeight: position == 1
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                if (status == 'waiting')
                  OutlinedButton.icon(
                    onPressed: () => _confirmLeave(context, data),
                    icon: const Icon(
                      Icons.exit_to_app,
                      color: AppTheme.errorRed,
                    ),
                    label: const Text(
                      'Leave Queue',
                      style: TextStyle(color: AppTheme.errorRed),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _confirmLeave(BuildContext context, Map<String, dynamic> data) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave the queue?'),
        content: const Text(
          "You'll lose your spot and need to check in again.\n\nNote: There's a 20-minute cooldown before you can re-join.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onLeaveQueue();
            },
            child: const Text(
              'Leave',
              style: TextStyle(color: AppTheme.errorRed),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Mini Map Widget ──────────────────────────────────────────────────────────

class MiniMapWidget extends StatefulWidget {
  final String? bookingId;
  final bool highlightDestination;

  const MiniMapWidget({
    super.key,
    required this.bookingId,
    this.highlightDestination = false,
  });

  @override
  State<MiniMapWidget> createState() => _MiniMapWidgetState();
}

class _MiniMapWidgetState extends State<MiniMapWidget> {
  final MapController _mapController = MapController();

  /// Where the tricycle is drawn, shared with the route line.
  final VehiclePosition _drawnAt = VehiclePosition();
  LatLng? _lastDriverPoint;

  /// This phone's own position, straight from GPS.
  ///
  /// The map used to draw the driver from `driverLatitude` on the booking —
  /// which this same phone writes, throttled to one write every couple of
  /// seconds, and then reads back over the network. On the driver's own
  /// screen that is a round trip to watch yourself move. The booking is
  /// still the fallback, for the moments before the first fix arrives.
  LatLng? _myPosition;
  StreamSubscription<Position>? _positionSub;

  @override
  void initState() {
    super.initState();
    _positionSub = LocationHub.instance
        .watch(
          const LocationNeed(interval: Duration(seconds: 1), distanceFilter: 3),
        )
        .listen(
          (p) {
            if (mounted) {
              setState(() => _myPosition = LatLng(p.latitude, p.longitude));
            }
          },
          onError: (Object e) =>
              debugPrint('Mini map: no position stream ($e)'),
        );
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _drawnAt.dispose();
    super.dispose();
  }

  void _recenterOnDriver() {
    if (_lastDriverPoint != null) {
      _mapController.move(_lastDriverPoint!, 15);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.bookingId == null) return const SizedBox.shrink();

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('bookings')
          .doc(widget.bookingId)
          .snapshots(),
      builder: (context, bookingSnap) {
        if (!bookingSnap.hasData) {
          return const SizedBox(
            height: 200,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final bookingData = bookingSnap.data!.data() as Map<String, dynamic>?;

        final pickupLat = bookingData?['pickupLatitude'] as double?;
        final pickupLng = bookingData?['pickupLongitude'] as double?;
        final driverLat = bookingData?['driverLatitude'] as double?;
        final driverLng = bookingData?['driverLongitude'] as double?;
        final destinationLat = bookingData?['destinationLatitude'] as double?;
        final destinationLng = bookingData?['destinationLongitude'] as double?;

        if (pickupLat == null || pickupLng == null) {
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              children: [
                Icon(Icons.warning_amber, color: AppTheme.warning, size: 16),
                SizedBox(width: 8),
                Text(
                  'Pickup location not set',
                  style: TextStyle(color: AppTheme.warning, fontSize: 13),
                ),
              ],
            ),
          );
        }

        final pickupPoint = LatLng(pickupLat, pickupLng);
        // Own GPS first: it is this phone's position without waiting for a
        // write and a read back.
        final driverPoint =
            _myPosition ??
            ((driverLat != null && driverLng != null)
                ? LatLng(driverLat, driverLng)
                : pickupPoint);
        final destinationPoint =
            (destinationLat != null && destinationLng != null)
            ? LatLng(destinationLat, destinationLng)
            : null;

        // Save driver point for recenter
        _lastDriverPoint = driverPoint;

        // Which end of the trip to emphasise. This follows the trip state
        // rather than only the manual Go to Pickup / Go to Destination
        // toggle: once the passenger is aboard, the destination is what the
        // driver is heading for, and drawing it as a faint grey dot while
        // the already-visited pickup stays big and orange makes the route
        // look like it stops short of anywhere.
        final navPhase = NavigationPhase.forTrip(
          TripState.fromMap(
            widget.bookingId ?? '',
            bookingData ?? const {},
          ).trip,
        );
        final showDestination =
            widget.highlightDestination ||
            navPhase == NavigationPhase.toDestination;

        return SizedBox(
          height: 200,
          child: Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: showDestination && destinationPoint != null
                        ? destinationPoint
                        : driverPoint,
                    initialZoom: widget.highlightDestination ? 14 : 15,
                  ),
                  children: [
                    AppTileLayer(),
                    TrafficOverlay(origin: driverPoint, radiusKm: 3),
                    // The route the driver is actually following, read from
                    // the shared record — so picking an alternative or being
                    // rerouted moves this line too. Drawn over the traffic
                    // colour, which sits on the same roads.
                    if (widget.bookingId != null)
                      TripRouteLayer(
                        bookingId: widget.bookingId!,
                        controller: _mapController,
                        // Same drawn position as the marker below, so the
                        // line starts under the tricycle rather than at a
                        // point that updates at a different rate.
                        follows: _drawnAt,
                        from: driverPoint,
                        to: showDestination && destinationPoint != null
                            ? destinationPoint
                            : pickupPoint,
                      ),
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: pickupPoint,
                          width: showDestination ? 30 : 45,
                          height: showDestination ? 30 : 45,
                          child: Icon(
                            Icons.flag,
                            color: showDestination
                                ? Colors.grey.withValues(alpha: 0.4)
                                : AppTheme.warning,
                            size: showDestination ? 20 : 35,
                          ),
                        ),
                        if (destinationPoint != null)
                          Marker(
                            point: destinationPoint,
                            width: showDestination ? 45 : 30,
                            height: showDestination ? 45 : 30,
                            child: Icon(
                              Icons.location_on,
                              color: showDestination
                                  ? AppTheme.errorRed
                                  : Colors.grey.withValues(alpha: 0.4),
                              size: showDestination ? 35 : 20,
                            ),
                          ),
                      ],
                    ),
                    // At the latest position this phone reported.
                    GlidingMarkerLayer(
                      target: driverPoint,
                      reports: _drawnAt,
                      child: const Icon(
                        Icons.electric_rickshaw,
                        color: AppTheme.primaryBlue,
                        size: 30,
                      ),
                    ),
                  ],
                ),
              ),
              // Recenter button
              Positioned(
                bottom: 8,
                right: 8,
                child: FloatingActionButton.small(
                  heroTag: 'minimap_recenter_${widget.bookingId ?? 'default'}',
                  backgroundColor: Colors.white,
                  tooltip: 'Recenter to driver',
                  onPressed: _recenterOnDriver,
                  child: const Icon(
                    Icons.my_location,
                    color: AppTheme.primaryBlue,
                    size: 18,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Routing Polyline ─────────────────────────────────────────────────────────

// ─── Driver Map Tab ───────────────────────────────────────────────────────────

class _DriverMapTab extends StatefulWidget {
  final bool isActive;
  const _DriverMapTab({required this.isActive});

  @override
  State<_DriverMapTab> createState() => _DriverMapTabState();
}

class _DriverMapTabState extends State<_DriverMapTab> {
  static const LatLng _baliwagCenter = LatLng(14.9540, 120.9010);

  final _geofence = GeofenceService.instance;
  final MapController _mapController = MapController();
  StreamSubscription<Position>? _positionSub;
  LatLng? _myPosition;
  double _zoom = 16;
  bool _locationUnavailable = false;
  String? _assignedTerminalName;
  List<RoadReport> _nearbyReports = const [];

  @override
  void initState() {
    super.initState();
    _loadAssignedTerminal();
    _startWatchingSelf();
  }

  Future<void> _loadAssignedTerminal() async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .get();
    if (mounted) {
      setState(() {
        _assignedTerminalName = doc.data()?['assignedTerminalName'];
      });
    }
  }

  @override
  void didUpdateWidget(covariant _DriverMapTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive) {
      _centerOnMe();
    }
  }

  void _centerOnMe() {
    final point = _myPosition;
    if (point == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mapController.move(point, _zoom);
    });
  }

  Future<void> _startWatchingSelf() async {
    final current = await _geofence.getCurrentPosition();
    if (current != null && mounted) {
      _updateMyPosition(LatLng(current.latitude, current.longitude));
      if (widget.isActive) _centerOnMe();
    }

    final started = await _geofence.startTracking();
    if (!started) {
      if (mounted) setState(() => _locationUnavailable = true);
      return;
    }

    _positionSub = _geofence.positionStream.listen((pos) {
      if (!mounted) return;
      _updateMyPosition(LatLng(pos.latitude, pos.longitude));
    });
  }

  void _updateMyPosition(LatLng point) {
    setState(() => _myPosition = point);
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    super.dispose();
  }

  LatLng? _parseBoundaryPoint(dynamic raw) {
    try {
      if (raw is GeoPoint) return LatLng(raw.latitude, raw.longitude);
      if (raw is List && raw.length >= 2) {
        final lat = _toDouble(raw[0]);
        final lng = _toDouble(raw[1]);
        if (lat != null && lng != null) return LatLng(lat, lng);
      }
      if (raw is Map) {
        final lat = _toDouble(raw['lat'] ?? raw['latitude']);
        final lng = _toDouble(raw['lng'] ?? raw['longitude']);
        if (lat != null && lng != null) return LatLng(lat, lng);
      }
    } catch (_) {}
    return null;
  }

  double? _toDouble(dynamic v) {
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('terminals').snapshots(),
      builder: (context, snapshot) {
        final terminals = snapshot.data?.docs ?? [];
        final markers = <Marker>[];
        final areas = <Polygon>[];

        for (final doc in terminals) {
          final data = doc.data() as Map<String, dynamic>;
          final boundary = data['boundary'] as List<dynamic>? ?? [];
          if (boundary.isEmpty) continue;

          final point = _parseBoundaryPoint(boundary[0]);
          if (point == null) continue;

          final isAssigned =
              _assignedTerminalName == null ||
              data['name'] == _assignedTerminalName;
          // The actual check-in area — the same outline the geofence tests
          // against. This used to be a 5 m circle on one corner of it, so
          // "drive into the highlighted circle" pointed at the wrong spot.
          final outline = boundary
              .map(_parseBoundaryPoint)
              .whereType<LatLng>()
              .toList();
          if (isAssigned && outline.length >= 3) {
            areas.add(
              Polygon(
                points: outline,
                color: AppTheme.primaryGreen.withValues(alpha: 0.3),
                borderColor: AppTheme.primaryGreen,
                borderStrokeWidth: 2,
              ),
            );
          }

          markers.add(
            Marker(
              point: point,
              width: 140,
              height: 60,
              child: GestureDetector(
                onTap: () {
                  showModalBottomSheet(
                    context: context,
                    builder: (_) => Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.location_on,
                                color: AppTheme.primaryGreen,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                data['name'] ?? 'Terminal',
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          StreamBuilder<QuerySnapshot>(
                            stream: FirebaseFirestore.instance
                                .collection('queueEntries')
                                .where('terminalId', isEqualTo: doc.id)
                                .where('status', isEqualTo: 'waiting')
                                .snapshots(),
                            builder: (context, qSnap) {
                              final count = qSnap.data?.docs.length ?? 0;
                              return Text(
                                '$count driver(s) currently waiting',
                                style: const TextStyle(
                                  color: AppTheme.textMuted,
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Drive into the highlighted area to check in automatically.',
                            style: TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color:
                            _assignedTerminalName == null ||
                                data['name'] == _assignedTerminalName
                            ? AppTheme.primaryGreen
                            : AppTheme.textMuted,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        data['name'] ?? 'Terminal',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      Icons.location_on,
                      color:
                          _assignedTerminalName == null ||
                              data['name'] == _assignedTerminalName
                          ? AppTheme.primaryGreen
                          : AppTheme.textMuted,
                      size: 24,
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _baliwagCenter,
                initialZoom: 15,
                onMapEvent: (event) {
                  _zoom = event.camera.zoom;
                },
              ),
              children: [
                AppTileLayer(),
                PolygonLayer(polygons: areas),
                // Drivers are the main source of these reports and the main
                // audience for them. Shaded under the markers so terminals
                // and vehicles stay readable on top of the traffic colour.
                TrafficOverlay(
                  origin: _myPosition ?? _baliwagCenter,
                  onReportsChanged: (reports) {
                    if (!mounted || reports.length == _nearbyReports.length) {
                      return;
                    }
                    setState(() => _nearbyReports = reports);
                  },
                ),
                MarkerLayer(markers: markers),
                // "You", at the latest GPS reading.
                GlidingMarkerLayer(
                  target: _myPosition,
                  child: const _SelfLocationDot(),
                ),
                const AppMapAttribution(),
              ],
            ),
            Positioned(
              top: 12,
              right: 12,
              child: GestureDetector(
                onTap: _nearbyReports.isEmpty
                    ? null
                    : () => showConditionsSheet(context, _nearbyReports),
                child: const TrafficLegend(),
              ),
            ),
            if (_locationUnavailable)
              Positioned(
                top: 12,
                left: 12,
                right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'Location is off — enable it to see yourself on the map.',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            Positioned(
              // Clear of the OpenStreetMap attribution in the corner.
              bottom: 72,
              left: 16,
              child: FloatingActionButton.extended(
                heroTag: 'driverReport',
                backgroundColor: AppTheme.warning,
                foregroundColor: Colors.white,
                onPressed: () => showReportSheet(context),
                icon: const Icon(Icons.add_alert),
                label: const Text('Report'),
              ),
            ),
            Positioned(
              bottom: 16,
              right: 16,
              child: FloatingActionButton.small(
                heroTag: 'recenter',
                backgroundColor: _myPosition != null
                    ? AppTheme.primaryGreen
                    : AppTheme.textMuted,
                tooltip: 'Recenter to my location',
                onPressed: _myPosition == null ? null : _centerOnMe,
                child: const Icon(Icons.my_location, color: Colors.white),
              ),
            ),
            Positioned(
              bottom: 80,
              right: 16,
              child: Column(
                children: [
                  FloatingActionButton.small(
                    heroTag: 'zoom_in',
                    backgroundColor: Colors.white,
                    tooltip: 'Zoom in',
                    onPressed: () {
                      _mapController.move(
                        _mapController.camera.center,
                        _zoom + 1,
                      );
                    },
                    child: const Icon(Icons.add, color: Colors.black87),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'zoom_out',
                    backgroundColor: Colors.white,
                    tooltip: 'Zoom out',
                    onPressed: () {
                      _mapController.move(
                        _mapController.camera.center,
                        _zoom - 1,
                      );
                    },
                    child: const Icon(Icons.remove, color: Colors.black87),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─── Self Location Dot ────────────────────────────────────────────────────────

class _SelfLocationDot extends StatelessWidget {
  const _SelfLocationDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.blue.withValues(alpha: 0.25),
      ),
      child: Center(
        child: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppTheme.info,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
          ),
        ),
      ),
    );
  }
}

// ─── Driver History Tab ───────────────────────────────────────────────────────

class _DriverHistoryTab extends StatefulWidget {
  final String uid;
  const _DriverHistoryTab({required this.uid});

  @override
  State<_DriverHistoryTab> createState() => _DriverHistoryTabState();
}

class _DriverHistoryTabState extends State<_DriverHistoryTab> {
  String get uid => widget.uid;

  Widget _detailRow(IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: AppTheme.textMuted),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                color: AppTheme.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
            Text(
              value,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('queueEntries')
          .where('driverId', isEqualTo: uid)
          .where('status', whereIn: ['completed', 'cancelled'])
          .orderBy('checkedInAt', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: List.generate(3, (_) => const ShimmerCard()),
          );
        }
        if (snapshot.hasError) {
          return ErrorView(
            message:
                'We couldn\'t load your trip history. Check your connection '
                'and try again.',
            onRetry: () => setState(() {}),
          );
        }
        final entries = snapshot.data?.docs ?? [];
        if (entries.isEmpty) {
          return const EmptyView(
            icon: Icons.history,
            title: 'No trips yet',
            message:
                'Check in at a terminal to join the queue. Completed trips '
                'will be listed here.',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final data = entries[index].data() as Map<String, dynamic>;
            final tripStatus = TripState.fromMap(entries[index].id, data).trip;
            final isCancelled = tripStatus == TripStatus.cancelled;
            final status = tripStatus.driverLabel;

            final checkedInAt = data['checkedInAt'] as Timestamp?;
            final completedAt = data['completedAt'] as Timestamp?;
            final cancelledAt = data['cancelledAt'] as Timestamp?;
            final cancelledReason = data['cancelledReason'] as String?;

            String dateStr = '';
            String timeStr = '';
            if (isCancelled && cancelledAt != null) {
              final dt = cancelledAt.toDate();
              dateStr = DateFormatter.formatDate(dt);
              timeStr = DateFormatter.formatTime(dt);
            } else if (completedAt != null) {
              final dt = completedAt.toDate();
              dateStr = DateFormatter.formatDate(dt);
              timeStr = DateFormatter.formatTime(dt);
            } else if (checkedInAt != null) {
              final dt = checkedInAt.toDate();
              dateStr = DateFormatter.formatDate(dt);
              timeStr = DateFormatter.formatTime(dt);
            }

            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: ExpansionTile(
                leading: CircleAvatar(
                  backgroundColor: isCancelled
                      ? Colors.red.shade100
                      : Colors.green.shade100,
                  child: Icon(
                    isCancelled ? Icons.cancel_outlined : Icons.check,
                    color: isCancelled ? AppTheme.errorRed : AppTheme.success,
                  ),
                ),
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        data['terminalName'] ?? 'Terminal',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    if (data['hasRating'] == true &&
                        data['viewedRating'] != true)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.errorRed,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'NEW',
                          style: TextStyle(
                            fontSize: 9,
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
                subtitle: Text(
                  isCancelled ? 'Cancelled — $dateStr' : 'Completed — $dateStr',
                  style: TextStyle(
                    color: isCancelled ? AppTheme.errorRed : AppTheme.success,
                    fontSize: 12,
                  ),
                ),
                trailing: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: isCancelled
                        ? Colors.red.withValues(alpha: 0.1)
                        : Colors.green.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      color: isCancelled
                          ? AppTheme.errorRed
                          : AppTheme.textMuted,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Divider(),
                        _detailRow(
                          Icons.access_time,
                          isCancelled ? 'Left at' : 'Completed at',
                          timeStr,
                        ),
                        const SizedBox(height: 8),
                        _detailRow(Icons.calendar_today, 'Date', dateStr),
                        if (data['passengerName'] != null) ...[
                          const SizedBox(height: 8),
                          _detailRow(
                            Icons.person,
                            'Passenger',
                            data['passengerName'],
                          ),
                        ],
                        // Fare and payment status live on the linked
                        // booking document, not on this queue entry.
                        if (data['bookingId'] != null)
                          StreamBuilder<DocumentSnapshot>(
                            stream: FirebaseFirestore.instance
                                .collection('bookings')
                                .doc(data['bookingId'] as String)
                                .snapshots(),
                            builder: (context, bookingSnap) {
                              final bookingData =
                                  bookingSnap.data?.data()
                                      as Map<String, dynamic>?;
                              if (bookingData == null) {
                                return const SizedBox.shrink();
                              }

                              final fare = bookingData['fare'] as num?;
                              final paymentStatus =
                                  TripState.fromMap('', bookingData).payment ==
                                      PaymentState.paymentConfirmed
                                  ? 'paid'
                                  : 'pending';
                              final paymentMethod =
                                  bookingData['paymentMethod'] as String?;
                              final isPaid = paymentStatus == 'paid';

                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (fare != null) ...[
                                    const SizedBox(height: 8),
                                    _detailRow(
                                      Icons.monetization_on,
                                      'Fare',
                                      '₱${fare.toStringAsFixed(0)}',
                                    ),
                                    const SizedBox(height: 8),
                                    _detailRow(
                                      Icons.payment,
                                      'Status',
                                      isPaid
                                          ? '✅ Paid${paymentMethod == 'gcash'
                                                ? ' (GCash)'
                                                : paymentMethod == 'cash'
                                                ? ' (Cash)'
                                                : ''}'
                                          : paymentMethod == 'cash'
                                          ? '⏳ Awaiting cash confirmation'
                                          : '⏳ Awaiting passenger payment',
                                    ),
                                  ],
                                  if (!isPaid && paymentMethod == 'cash')
                                    Padding(
                                      padding: const EdgeInsets.only(top: 12),
                                      child: SizedBox(
                                        width: double.infinity,
                                        child: ElevatedButton.icon(
                                          onPressed: () async {
                                            await DispatchService.instance
                                                .confirmPayment(
                                                  bookingId:
                                                      data['bookingId']
                                                          as String,
                                                  paymentMethod: 'cash',
                                                );
                                            if (context.mounted) {
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                const SnackBar(
                                                  content: Text(
                                                    '✅ Cash payment confirmed!',
                                                  ),
                                                ),
                                              );
                                            }
                                          },
                                          icon: const Icon(
                                            Icons.check_circle,
                                            size: 16,
                                          ),
                                          label: const Text(
                                            'Confirm Cash Received',
                                          ),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor:
                                                AppTheme.primaryGreen,
                                            foregroundColor: Colors.white,
                                            textStyle: const TextStyle(
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                        if (isCancelled && cancelledReason != null) ...[
                          const SizedBox(height: 8),
                          _detailRow(
                            Icons.info_outline,
                            'Reason',
                            cancelledReason,
                          ),
                        ],
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () {
                              if (!isCancelled && data['bookingId'] != null) {
                                Navigator.pushNamed(
                                  context,
                                  AppRoutes.tripDetail,
                                  arguments: {
                                    'bookingId': data['bookingId'],
                                    'userRole': 'driver',
                                  },
                                );
                              } else {
                                showDialog(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: Row(
                                      children: [
                                        Icon(
                                          isCancelled
                                              ? Icons.cancel_outlined
                                              : Icons.check_circle,
                                          color: isCancelled
                                              ? AppTheme.errorRed
                                              : AppTheme.success,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          isCancelled
                                              ? 'Cancelled Trip'
                                              : 'Trip Details',
                                        ),
                                      ],
                                    ),
                                    content: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        _detailRow(
                                          Icons.location_on,
                                          'Terminal',
                                          data['terminalName'] ?? 'Terminal',
                                        ),
                                        const SizedBox(height: 8),
                                        _detailRow(
                                          Icons.access_time,
                                          'Time',
                                          '$timeStr on $dateStr',
                                        ),
                                        const SizedBox(height: 8),
                                        if (data['passengerName'] != null) ...[
                                          _detailRow(
                                            Icons.person,
                                            'Passenger',
                                            data['passengerName'],
                                          ),
                                          const SizedBox(height: 8),
                                        ],
                                        _detailRow(
                                          Icons.info_outline,
                                          'Status',
                                          isCancelled
                                              ? 'Cancelled'
                                              : 'Completed',
                                        ),
                                        const SizedBox(height: 8),
                                        if (isCancelled &&
                                            cancelledReason != null)
                                          _detailRow(
                                            Icons.info_outline,
                                            'Reason',
                                            cancelledReason,
                                          ),
                                      ],
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(ctx),
                                        child: const Text('Close'),
                                      ),
                                    ],
                                  ),
                                );
                              }
                            },
                            icon: Icon(
                              isCancelled
                                  ? Icons.info_outline
                                  : Icons.receipt_long,
                              size: 16,
                            ),
                            label: Text(
                              isCancelled
                                  ? 'View Details'
                                  : 'View Trip Details',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// ─── Driver Profile Tab ───────────────────────────────────────────────────────

class _DriverProfileTab extends StatefulWidget {
  final String uid;
  const _DriverProfileTab({required this.uid});

  @override
  State<_DriverProfileTab> createState() => _DriverProfileTabState();
}

class _DriverProfileTabState extends State<_DriverProfileTab> {
  bool _darkMode = false;

  Future<void> _uploadProfilePicture(BuildContext context) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final picker = ImagePicker();

    // Show source selection dialog
    final source = await showDialog<ImageSource>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change Profile Photo'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.camera_alt,
                color: AppTheme.primaryGreen,
              ),
              title: const Text('Take Photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(
                Icons.photo_library,
                color: AppTheme.primaryBlue,
              ),
              title: const Text('Choose from Gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: AppTheme.errorRed),
              title: const Text('Remove Photo'),
              onTap: () async {
                await FirebaseFirestore.instance
                    .collection('users')
                    .doc(uid)
                    .update({'profilePhotoUrl': FieldValue.delete()});
                if (ctx.mounted) Navigator.pop(ctx);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('✅ Photo removed!')),
                  );
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (source == null) return;

    final pickedFile = await picker.pickImage(
      source: source,
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 80,
    );

    if (pickedFile == null) return;

    final file = File(pickedFile.path);
    final url = await CloudinaryService.instance.uploadImage(
      file,
      'profile_photos/$uid',
    );

    if (url != null) {
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'profilePhotoUrl': url,
      });
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Profile photo updated!')),
        );
      }
    }
  }

  void _showEditPhoneDialog(BuildContext context) {
    final phoneController = TextEditingController();
    final uid = FirebaseAuth.instance.currentUser!.uid;

    // Pre-fill existing phone
    ContactService.instance.mine().then((contact) {
      phoneController.text = contact.phone ?? '';
    });

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Phone Number'),
        content: TextField(
          controller: phoneController,
          keyboardType: TextInputType.phone,
          maxLength: 11,
          decoration: const InputDecoration(
            labelText: 'Phone Number',
            prefixIcon: Icon(Icons.phone_outlined),
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final phone = phoneController.text.trim();
              if (phone.isEmpty || phone.length != 11) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Phone must be 11 digits')),
                );
                return;
              }
              if (!RegExp(r'^[0-9]+$').hasMatch(phone)) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Phone must be numbers only')),
                );
                return;
              }
              // Into the private record, not the user document every
              // signed-in account can read.
              await ContactService.instance.save(uid, Contact(phone: phone));
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('✅ Phone updated!')),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryGreen,
            ),
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showEditLocationDialog(BuildContext context) {
    final locationController = TextEditingController();
    final uid = FirebaseAuth.instance.currentUser!.uid;

    // Pre-fill existing address
    FirebaseFirestore.instance.collection('users').doc(uid).get().then((doc) {
      locationController.text = doc.data()?['locationAddress'] ?? '';
    });

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Location Address'),
        content: TextField(
          controller: locationController,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Location Address',
            hintText: 'House no., street, barangay, city',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (locationController.text.trim().isEmpty) return;
              await FirebaseFirestore.instance
                  .collection('users')
                  .doc(uid)
                  .update({'locationAddress': locationController.text.trim()});
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('✅ Location updated!')),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryGreen,
            ),
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showChangePasswordDialog(BuildContext context) {
    final currentController = TextEditingController();
    final newController = TextEditingController();
    final confirmController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final newPass = newController.text;
          final confirmPass = confirmController.text;
          final currentPass = currentController.text;

          // Real-time validation checks
          final hasMinLength = newPass.length >= 8;
          final hasUppercase = RegExp(r'[A-Z]').hasMatch(newPass);
          final hasNumber = RegExp(r'[0-9]').hasMatch(newPass);
          final isDifferentFromCurrent =
              newPass.isEmpty || newPass != currentPass;
          final passwordsMatch = confirmPass.isEmpty || newPass == confirmPass;

          return AlertDialog(
            title: const Text('Change Password'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Current password
                  TextField(
                    controller: currentController,
                    obscureText: true,
                    onChanged: (v) => setDialogState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Current Password',
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // New password
                  TextField(
                    controller: newController,
                    obscureText: true,
                    onChanged: (v) => setDialogState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'New Password',
                      prefixIcon: Icon(Icons.lock_reset),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Real-time requirement indicators
                  if (newPass.isNotEmpty) ...[
                    const Text(
                      'Password Requirements:',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textMuted,
                      ),
                    ),
                    const SizedBox(height: 4),
                    _buildRequirementRow(hasMinLength, 'At least 8 characters'),
                    const SizedBox(height: 2),
                    _buildRequirementRow(
                      hasUppercase,
                      'At least 1 uppercase letter',
                    ),
                    const SizedBox(height: 2),
                    _buildRequirementRow(hasNumber, 'At least 1 number'),
                    const SizedBox(height: 2),
                    _buildRequirementRow(
                      isDifferentFromCurrent,
                      'Different from current password',
                    ),
                  ],
                  const SizedBox(height: 12),

                  // Confirm password
                  TextField(
                    controller: confirmController,
                    obscureText: true,
                    onChanged: (v) => setDialogState(() {}),
                    decoration: InputDecoration(
                      labelText: 'Confirm New Password',
                      prefixIcon: const Icon(Icons.check_circle_outline),
                      errorText: confirmPass.isNotEmpty && !passwordsMatch
                          ? 'Passwords do not match'
                          : null,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () async {
                  final current = currentController.text;
                  final newPass = newController.text;
                  final confirm = confirmController.text;

                  if (current.isEmpty || newPass.isEmpty || confirm.isEmpty) {
                    return;
                  }

                  final isValid =
                      hasMinLength &&
                      hasUppercase &&
                      hasNumber &&
                      isDifferentFromCurrent &&
                      passwordsMatch;

                  if (!isValid) {
                    return;
                  }

                  try {
                    final user = FirebaseAuth.instance.currentUser!;
                    final credential = EmailAuthProvider.credential(
                      email: user.email!,
                      password: current,
                    );
                    await user.reauthenticateWithCredential(credential);
                    await user.updatePassword(newPass);
                    if (context.mounted) {
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('✅ Password changed successfully!'),
                        ),
                      );
                    }
                  } catch (e) {
                    if (!context.mounted) return;
                    setDialogState(() {});
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'That current password doesn\'t match. Please try again.',
                        ),
                      ),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryGreen,
                ),
                child: const Text(
                  'Change Password',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildRequirementRow(bool isMet, String requirement) {
    return Row(
      children: [
        Icon(
          isMet ? Icons.check_circle : Icons.cancel,
          size: 14,
          color: isMet ? AppTheme.success : AppTheme.errorRed,
        ),
        const SizedBox(width: 6),
        Text(
          requirement,
          style: TextStyle(
            fontSize: 11,
            color: isMet ? AppTheme.success : AppTheme.errorRed,
            fontWeight: isMet ? FontWeight.w500 : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  void _showTermsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          'Terms & Conditions',
          textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'TODA E-QUEUE+',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.primaryGreen,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Terms and Conditions & Privacy Policy',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
                ),
                const SizedBox(height: 20),

                const Text(
                  '1. ACCEPTANCE OF TERMS',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'By registering and using TODA E-QUEUE+ (the "App"), you agree to be bound by these Terms and Conditions. If you do not agree, you must not use the App.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '2. DESCRIPTION OF SERVICE',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'TODA E-QUEUE+ is a geo-fenced queue management, booking, and safety system for the Federation of Baliwag City TODA. Features include automated queue management, passenger booking, GPS trip tracking, fare calculation, and emergency SOS.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '3. DRIVER RESPONSIBILITIES',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  '• Provide valid identification documents\n'
                  '• Maintain a valid tricycle franchise\n'
                  '• Follow TODA regulations and city ordinances\n'
                  '• Stay within assigned terminal geofence when queuing\n'
                  '• Complete accepted bookings in a timely manner\n'
                  '• Honor the fare calculated by the system\n'
                  '• Maintain professional conduct at all times\n'
                  '• Report incidents or violations promptly',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '4. PASSENGER RESPONSIBILITIES',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  '• Provide accurate booking information\n'
                  '• Be at the designated pickup location on time\n'
                  '• Pay the calculated fare upon trip completion\n'
                  '• Treat drivers with respect\n'
                  '• Use SOS feature only for genuine emergencies\n'
                  '• Not engage in fraudulent activities',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '5. FARE POLICY',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                // The rates in force, not the ones the app shipped with.
                Text(
                  '${FareService.instance.policyLines}\n'
                  '• Fares calculated based on GPS road distance\n'
                  '• Payment accepted: Cash or GCash QR code\n'
                  '• Fares are non-negotiable',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '6. QUEUE MANAGEMENT',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  '• Drivers must be within designated geofence to join queue\n'
                  '• Queue follows FIFO (First-In, First-Out) order\n'
                  '• Drivers who leave queue go to the back upon re-entry\n'
                  '• 20-minute cooldown applies after leaving queue\n'
                  '• Unverified drivers are not permitted in the queue',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '7. CANCELLATION POLICY',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  '• Passengers may cancel before driver accepts\n'
                  '• Cancellation restricted after driver acceptance\n'
                  '• Repeated cancellations may result in restrictions\n'
                  '• Drivers who cancel without valid reason face penalties',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '8. PRIVACY POLICY',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Information We Collect:\n'
                  '• Name, email, phone number\n'
                  '• GPS location during active trips\n'
                  '• Profile photos and verification documents\n'
                  '• Trip history and payment records\n'
                  '• Ratings and feedback',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'How We Use Your Information:\n'
                  '• To provide transportation services\n'
                  '• To verify driver credentials\n'
                  '• To process bookings and payments\n'
                  '• To send important notifications\n'
                  '• To respond to SOS emergencies',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Data Protection:\n'
                  '• Data stored securely in Firebase Cloud Firestore\n'
                  '• Personal information never sold to third parties\n'
                  '• GPS only active during trips or queue participation\n'
                  '• Users may request data deletion',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '9. EMERGENCY FEATURES',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  '• SOS button sends alert with location to TODA admin\n'
                  '• SOS should only be used in genuine emergencies\n'
                  '• Misuse may result in account suspension',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '10. RATING SYSTEM',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  '• Passengers may rate drivers 1-5 stars\n'
                  '• Drivers may respond to ratings\n'
                  '• Ratings are visible to other users\n'
                  '• Continuous low ratings may affect privileges',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '11. LIMITATION OF LIABILITY',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'TODA E-QUEUE+ is a platform connecting drivers and passengers. We do not provide transportation services directly and are not liable for incidents during trips.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '12. TERMINATION',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'We reserve the right to suspend accounts for violation of terms, fraudulent activity, or misuse of emergency features.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '13. CONTACT',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Federation of Baliwag City TODA\n'
                  'Email: fedbaliwagtoda@gmail.com\n'
                  'Baliwag City Hall, Bulacan',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _uploadGcashQr(BuildContext context) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 80,
    );

    if (pickedFile == null) return;

    final file = File(pickedFile.path);
    final url = await CloudinaryService.instance.uploadImage(
      file,
      'gcash_qr/${widget.uid}',
    );

    if (url != null) {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.uid)
          .update({'gcashQrUrl': url});
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('✅ GCash QR uploaded!')));
      }
    }
  }

  void _showReplyDialog(BuildContext context, String ratingId) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reply to Rating'),
        content: GestureDetector(
          onTap: () => FocusScope.of(ctx).unfocus(),
          child: TextField(
            controller: controller,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'Write your reply...',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (controller.text.trim().isEmpty) return;
              await FirebaseFirestore.instance
                  .collection('ratings')
                  .doc(ratingId)
                  .update({
                    'driverReply': controller.text.trim(),
                    'repliedAt': FieldValue.serverTimestamp(),
                  });
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Send Reply'),
          ),
        ],
      ),
    );
  }

  void _showRatingDetails(BuildContext context, String driverId) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('ratings')
            .where('driverId', isEqualTo: driverId)
            .orderBy('createdAt', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          final ratings = snapshot.data?.docs ?? [];
          return Container(
            padding: const EdgeInsets.all(24),
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.5,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Your Ratings',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                if (ratings.isEmpty)
                  const Center(child: Text('No ratings yet.'))
                else
                  Expanded(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: ratings.length,
                      itemBuilder: (context, index) {
                        final r = ratings[index].data() as Map<String, dynamic>;
                        final stars = r['rating'] ?? 0;
                        final comment = r['comment'] ?? '';
                        final driverReply = r['driverReply'] ?? '';
                        final date = DateFormatter.formatDate(
                          (r['createdAt'] as Timestamp?)?.toDate(),
                        );
                        final passengerId = r['passengerId'] ?? '';
                        final ratingId = ratings[index].id;

                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    ...List.generate(
                                      5,
                                      (i) => Icon(
                                        i < stars
                                            ? Icons.star
                                            : Icons.star_border,
                                        color: Colors.amber,
                                        size: 18,
                                      ),
                                    ),
                                    const Spacer(),
                                    Text(
                                      date,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: AppTheme.textMuted,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                FutureBuilder<DocumentSnapshot>(
                                  future: FirebaseFirestore.instance
                                      .collection('users')
                                      .doc(passengerId)
                                      .get(),
                                  builder: (context, userSnap) {
                                    final passengerName =
                                        userSnap.data?['name'] ?? 'Passenger';
                                    final firstLetter = passengerName
                                        .substring(0, 1)
                                        .toUpperCase();
                                    return Row(
                                      children: [
                                        CircleAvatar(
                                          radius: 16,
                                          backgroundColor: AppTheme.primaryGreen
                                              .withValues(alpha: 0.2),
                                          child: Text(
                                            firstLetter,
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: AppTheme.primaryGreen,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          passengerName,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                                if (comment.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    comment,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.textMuted,
                                    ),
                                  ),
                                ],
                                if (driverReply.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: AppTheme.primaryBlue.withValues(
                                        alpha: 0.05,
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: AppTheme.primaryBlue.withValues(
                                          alpha: 0.2,
                                        ),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'Your reply:',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: AppTheme.primaryBlue,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          driverReply,
                                          style: const TextStyle(fontSize: 13),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                                if (driverReply.isEmpty) ...[
                                  const SizedBox(height: 8),
                                  TextButton.icon(
                                    onPressed: () =>
                                        _showReplyDialog(context, ratingId),
                                    icon: const Icon(Icons.reply, size: 16),
                                    label: const Text(
                                      'Reply',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showHelpTopics(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Help Topics'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '1. How to join the queue?',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text('Drive into your assigned terminal geofence area.'),
              SizedBox(height: 12),
              Text(
                '2. How to accept a booking?',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text('Tap "Accept Booking" when you get dispatched.'),
              SizedBox(height: 12),
              Text(
                '3. How to use SOS?',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text('Tap the red SOS button in an emergency.'),
              SizedBox(height: 12),
              Text(
                '4. How to upload GCash QR?',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text('Go to Profile → Upload GCash QR.'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(widget.uid)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snapshot.data!.data() as Map<String, dynamic>?;
        final isVerified = data?['isVerified'] ?? false;

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const SizedBox(height: 24),
            Center(
              child: Column(
                children: [
                  GestureDetector(
                    onTap: () => _uploadProfilePicture(context),
                    child: CircleAvatar(
                      radius: 48,
                      backgroundColor: AppTheme.primaryBlue,
                      backgroundImage: data?['profilePhotoUrl'] != null
                          ? NetworkImage(data!['profilePhotoUrl'])
                          : null,
                      child: data?['profilePhotoUrl'] == null
                          ? Text(
                              (data?['name'] ?? 'D').toString().substring(0, 1),
                              style: const TextStyle(
                                fontSize: 36,
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Tap to change photo',
                    style: TextStyle(fontSize: 10, color: AppTheme.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                data?['name'] ?? 'Driver',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: isVerified
                      ? Colors.green.withValues(alpha: 0.1)
                      : Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  isVerified ? '✅ Verified Driver' : '⏳ Pending Verification',
                  style: TextStyle(
                    color: isVerified ? AppTheme.success : AppTheme.warning,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            if ((data?['averageRating'] ?? 0) > 0)
              GestureDetector(
                onTap: () => _showRatingDetails(context, widget.uid),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.star, color: Colors.amber, size: 20),
                      const SizedBox(width: 4),
                      Text(
                        '${data?['averageRating']} (${data?['totalRatings']} ratings)',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: AppTheme.textMuted,
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 32),

            // Personal Info Card
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // A driver's name is the one checked against their ID when
                  // they were approved, so only an admin changes it. Letting
                  // the driver edit it meant the approved name and the one
                  // passengers see could drift apart unreviewed.
                  ListTile(
                    leading: const Icon(Icons.person_outlined),
                    title: const Text('Full Name'),
                    subtitle: Text(data?['name'] ?? ''),
                    trailing: const Icon(Icons.lock_outline, size: 16),
                    onTap: () => showDialog<void>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Name is locked'),
                        content: const Text(
                          'Your name was checked against your ID when you '
                          'were approved, so it can only be changed by your '
                          'TODA admin. Ask them to update it.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('OK'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.email_outlined),
                    title: const Text('Email'),
                    // Known locally from the signed-in account, rather than
                    // read back off a document other people can see.
                    subtitle: Text(
                      FirebaseAuth.instance.currentUser?.email ?? '',
                    ),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  MyContact(
                    builder: (context, contact) => ListTile(
                      leading: const Icon(Icons.phone_outlined),
                      title: const Text('Phone'),
                      subtitle: Text(contact.phone ?? 'Not set'),
                      trailing: const Icon(Icons.edit, size: 16),
                      onTap: () => _showEditPhoneDialog(context),
                    ),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  // Edit Location — inside Personal Info
                  ListTile(
                    leading: const Icon(
                      Icons.home_outlined,
                      color: AppTheme.info,
                    ),
                    title: const Text('Location Address'),
                    subtitle: Text(
                      data?['locationAddress'] ?? 'Not set',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: const Icon(Icons.edit, size: 16),
                    onTap: () => _showEditLocationDialog(context),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.verified_user_outlined),
                    title: const Text('Role'),
                    subtitle: Text(data?['role'] ?? 'passenger'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // My road reports — the dependable way to take one down; see
            // MyReportsScreen for why the map alone was not enough.
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListTile(
                leading: const Icon(
                  Icons.flag_outlined,
                  color: AppTheme.warning,
                ),
                title: const Text(
                  'My road reports',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: const Text('See what you reported, or take it down'),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => MyReportsScreen.open(context),
              ),
            ),
            const SizedBox(height: 16),

            // Privacy & Security Card
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ListTile(
                    leading: Icon(Icons.shield, color: AppTheme.primaryGreen),
                    title: Text(
                      'Privacy & Security',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(
                      Icons.lock_outline,
                      color: AppTheme.warning,
                    ),
                    title: const Text('Change Password'),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () => _showChangePasswordDialog(context),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(
                      Icons.description_outlined,
                      color: AppTheme.textMuted,
                    ),
                    title: const Text('Terms & Conditions'),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () => _showTermsDialog(context),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // GCash QR Card
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(
                      Icons.qr_code,
                      color: AppTheme.primaryGreen,
                    ),
                    title: const Text('GCash Payment QR'),
                    subtitle: Text(
                      data?['gcashQrUrl'] != null
                          ? '✅ QR Code uploaded'
                          : 'No QR code uploaded yet',
                    ),
                  ),
                  if (data?['gcashQrUrl'] != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Image.network(
                        data!['gcashQrUrl'],
                        height: 200,
                        fit: BoxFit.contain,
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: OutlinedButton.icon(
                      onPressed: () => _uploadGcashQr(context),
                      icon: const Icon(Icons.upload),
                      label: const Text('Upload GCash QR'),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Settings Card
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.dark_mode_outlined),
                    title: const Text('Dark Mode'),
                    subtitle: const Text('Use dark theme'),
                    value: _darkMode,
                    onChanged: (value) {
                      setState(() => _darkMode = value);
                      ThemeController.instance.toggleTheme(value);
                    },
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // About Card
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.info_outlined),
                    title: const Text('About App'),
                    subtitle: const Text('TODA E-QUEUE+ v1.0.0'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.pushNamed(context, AppRoutes.about),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Help Center Card
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(
                      Icons.bug_report,
                      color: AppTheme.warning,
                    ),
                    title: const Text('Send Ticket / Report Issue'),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.sendTicket),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.help_outlined),
                    title: const Text('Help Topics'),
                    subtitle: const Text('Frequently asked questions'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _showHelpTopics(context),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Sign Out'),
                    content: const Text('Are you sure you want to sign out?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text(
                          'Sign Out',
                          style: TextStyle(color: AppTheme.errorRed),
                        ),
                      ),
                    ],
                  ),
                );
                if (confirm == true && context.mounted) {
                  await FirebaseAuth.instance.signOut();
                  if (!context.mounted) return;
                  Navigator.pushReplacementNamed(context, AppRoutes.login);
                }
              },
              icon: const Icon(Icons.logout, color: AppTheme.errorRed),
              label: const Text(
                'Sign Out',
                style: TextStyle(color: AppTheme.errorRed),
              ),
            ),
            const SizedBox(height: 24),
            const Center(
              child: Text(
                'TODA E-QUEUE+ v1.0.0',
                style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
              ),
            ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }
}

/// Heading for an accepted trip, driven by the trip state machine.
///
/// The surrounding card keys off the legacy `status` field, which maps
/// driverAccepted, driverOnTheWay, driverArrived, readyToStart and
/// tripInProgress all onto 'accepted'. A fixed "navigate to the pickup
/// location" was therefore still on screen once the passenger was aboard
/// and the driver was being routed to the destination — the card and the
/// map contradicting each other.
class _AcceptedTripHeading extends StatelessWidget {
  const _AcceptedTripHeading({required this.bookingId});

  final String bookingId;

  @override
  Widget build(BuildContext context) {
    if (bookingId.isEmpty) return const SizedBox.shrink();

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('bookings')
          .doc(bookingId)
          .snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data();
        if (data == null) return const SizedBox.shrink();

        final trip = TripState.fromMap(bookingId, data).trip;
        final phase = NavigationPhase.forTrip(trip);

        final (icon, colour, title, subtitle) = switch (trip) {
          TripStatus.driverArrived => (
            Icons.pin_drop,
            AppTheme.info,
            'You have arrived at the pickup',
            'Wait for your passenger.',
          ),
          TripStatus.readyToStart => (
            Icons.play_circle_outline,
            AppTheme.success,
            'Ready to start the trip',
            'Payment is confirmed.',
          ),
          TripStatus.tripInProgress => (
            Icons.navigation,
            AppTheme.primaryBlue,
            'Trip in progress',
            'Navigate to the destination.',
          ),
          _ => (
            Icons.check_circle,
            AppTheme.success,
            'Booking accepted',
            'Navigate to the pickup location.',
          ),
        };

        return Column(
          children: [
            Icon(icon, color: colour, size: 40),
            const SizedBox(height: 8),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: colour,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
            if (phase == NavigationPhase.atPickup) ...[
              const SizedBox(height: 4),
              const Text(
                'Navigation resumes when the trip starts.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// Switches the mini map from the pickup leg to the destination leg.
///
/// Replaces the old pair of "Go to Pickup" / "Go to Destination" toggles.
/// Those were always both offered, which asked the driver to keep track of
/// something the trip already knows: on the way to the passenger there is
/// only one place to go, and once the trip is under way the destination is
/// the only thing worth showing.
///
/// So this appears at exactly one moment — the driver has reached the
/// passenger but the trip has not started — and lets them look ahead at the
/// destination while they wait. It changes what the map draws and nothing
/// else; the trip itself still only moves through TripService.
class _DestinationSwitch extends StatelessWidget {
  const _DestinationSwitch({
    required this.bookingId,
    required this.showingDestination,
    required this.onChanged,
  });

  final String bookingId;
  final bool showingDestination;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('bookings')
          .doc(bookingId)
          .snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data();
        if (data == null) return const SizedBox.shrink();

        final phase = NavigationPhase.forTrip(
          TripState.fromMap(bookingId, data).trip,
        );

        // Under way: the destination is already what the map shows.
        if (phase == NavigationPhase.toDestination) {
          return const _MapLegNotice(
            icon: Icons.flag,
            text: 'Map is showing the route to the destination.',
          );
        }

        // Still driving to the passenger — nothing to switch to yet.
        if (phase != NavigationPhase.atPickup) {
          // Clear a preview left over from an earlier leg, so the next trip
          // does not start out drawing the wrong end of the journey.
          if (showingDestination) {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => onChanged(false),
            );
          }
          return const _MapLegNotice(
            icon: Icons.person_pin_circle,
            text: 'Map is showing the route to the passenger.',
          );
        }

        return SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton.icon(
            onPressed: () => onChanged(!showingDestination),
            icon: Icon(
              showingDestination ? Icons.person_pin_circle : Icons.flag,
              size: 18,
            ),
            label: Text(
              showingDestination
                  ? 'Show route to passenger'
                  : 'Show route to destination',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: showingDestination
                  ? AppTheme.warning
                  : AppTheme.errorRed,
              side: BorderSide(
                color: showingDestination
                    ? AppTheme.warning
                    : AppTheme.errorRed,
                width: 2,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Says which leg the map is drawing, for the times there is no choice.
class _MapLegNotice extends StatelessWidget {
  const _MapLegNotice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: AppTheme.textMuted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
          ),
        ),
      ],
    );
  }
}

/// Who the driver is picking up, with Call and Message.
///
/// The profile is fetched once. It used to be fetched inside the build, so
/// every refresh of the trip screen — several a minute while the trip's
/// record updates — read the passenger's profile from the database again.
class _PassengerCard extends StatefulWidget {
  const _PassengerCard({
    required this.passengerId,
    required this.bookingId,
    required this.onCall,
    required this.onMessage,
  });

  /// The trip whose message thread this card opens, and whose record
  /// carries the passenger's phone number.
  final String bookingId;

  final String? passengerId;
  final void Function(String) onCall;
  final void Function(String) onMessage;

  @override
  State<_PassengerCard> createState() => _PassengerCardState();
}

class _PassengerCardState extends State<_PassengerCard> {
  late Future<DocumentSnapshot<Map<String, dynamic>>>? _profile = _load();

  /// The passenger's number, taken from the booking — their own app writes
  /// it there when they book. It used to come from their user record, which
  /// is how every signed-in account could read all 78 phone numbers in the
  /// database.
  String? _phone;

  Future<DocumentSnapshot<Map<String, dynamic>>>? _load() {
    final id = widget.passengerId;
    if (id == null || id.isEmpty) return null;
    return FirebaseFirestore.instance.collection('users').doc(id).get();
  }

  @override
  void initState() {
    super.initState();
    _loadPhone();
  }

  Future<void> _loadPhone() async {
    if (widget.bookingId.isEmpty) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('bookings')
          .doc(widget.bookingId)
          .get();
      if (mounted) {
        setState(() => _phone = snap.data()?['passengerPhone'] as String?);
      }
    } catch (e) {
      // Call simply stays unavailable; the trip is unaffected.
      debugPrint('Passenger card: no number on the booking ($e)');
    }
  }

  @override
  void didUpdateWidget(_PassengerCard old) {
    super.didUpdateWidget(old);
    if (old.passengerId != widget.passengerId) _profile = _load();
    if (old.bookingId != widget.bookingId) _loadPhone();
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    if (profile == null) return const SizedBox.shrink();
    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: profile,
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        final data = snap.data!.data();
        final rawName = (data?['name'] as String?)?.trim();
        final name = (rawName == null || rawName.isEmpty)
            ? 'Passenger'
            : rawName;
        final photo = data?['profilePhotoUrl'] as String?;
        // From the booking, which the passenger's own app wrote — not from
        // their user record, which is no longer readable by other people.
        final phone = dialableNumber(_phone);

        return Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: AppTheme.primaryGreen,
                    backgroundImage: photo != null ? NetworkImage(photo) : null,
                    child: photo == null
                        ? Text(
                            name.substring(0, 1).toUpperCase(),
                            style: const TextStyle(
                              fontSize: 18,
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Passenger',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.textMuted,
                          ),
                        ),
                        Text(
                          name,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          phone ?? 'No phone number on file',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (phone != null) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => widget.onCall(phone),
                      icon: const Icon(Icons.call, size: 16),
                      label: const Text('Call', style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.primaryBlue,
                        side: const BorderSide(color: AppTheme.primaryBlue),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                // In-app messages: they reach the passenger without either
                // side learning the other's number, and arrive while the
                // trip is running.
                if (widget.bookingId.isNotEmpty)
                  Expanded(
                    child: MessageButton(
                      bookingId: widget.bookingId,
                      role: MessageSender.driver,
                      otherName: name,
                      speakIncoming: true,
                      compact: true,
                    ),
                  ),
                // SMS stays as a way out: it reaches a passenger whose app
                // is closed, which in-app messages cannot.
                if (phone != null) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Send an SMS instead',
                    onPressed: () => widget.onMessage(phone),
                    icon: const Icon(Icons.sms_outlined, size: 20),
                    color: AppTheme.textMuted,
                  ),
                ],
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Tells the screen when the app is hidden or shown, so a driver who
/// switches away or closes the app stops counting as online.
class _LifecycleWatcher extends WidgetsBindingObserver {
  _LifecycleWatcher({required this.onHidden, required this.onShown});

  final VoidCallback onHidden;
  final VoidCallback onShown;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        onShown();
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        onHidden();
      case AppLifecycleState.inactive:
        break; // a passing interruption, not away
    }
  }
}

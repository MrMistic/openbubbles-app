import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_location_clipper.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_pin_clipper.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/content/next_button.dart';
import 'package:bluebubbles/app/wrappers/scrollbar_wrapper.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/settings_widgets.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_popup/flutter_map_marker_popup.dart';
import 'package:get/get.dart' hide Response;
import 'package:latlong2/latlong.dart';
import 'package:maps_launcher/maps_launcher.dart';
import 'package:sliding_up_panel2/sliding_up_panel2.dart';
import 'package:tuple/tuple.dart';
import 'package:universal_io/io.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:url_launcher/url_launcher.dart';

class FindMyPage extends StatefulWidget {
  FindMyPage({super.key, this.defaultFriend, this.initialLocation, this.initialLabel});

  String? defaultFriend;

  /// When set, the map opens centered on this coordinate with a dropped pin.
  /// Used for opening a received maps.apple.com link at its coordinates.
  final LatLng? initialLocation;

  /// Optional label for the [initialLocation] pin popup (e.g. the place query).
  final String? initialLabel;

  @override
  State<StatefulWidget> createState() => _FindMyPageState();
}

class _FindMyPageState extends OptimizedState<FindMyPage> with SingleTickerProviderStateMixin {
  final ScrollController controller1 = ScrollController();
  final ScrollController controller2 = ScrollController();
  late final TabController tabController = TabController(vsync: this, length: 2);
  final PanelController panelController = PanelController();
  final RxInt index = 0.obs;
  final PopupController popupController = PopupController();
  final MapController mapController = MapController();
  final completer = Completer<void>();

  StreamSubscription? locationSub;
  List<FindMyDevice> devices = [];
  List<FindMyFriend> friends = [];
  List<FindMyFriend> friendsWithLocation = [];
  List<FindMyFriend> friendsWithoutLocation = [];
  Map<String, Marker> markers = {};
  Position? location;
  bool? fetching = true;
  bool refreshing = false;
  bool? fetching2 = true;
  bool refreshing2 = false;
  bool canRefresh = false;
  bool isInClique = true;

  /// Human-readable reason the last devices/friends load failed, shown instead of
  /// a bare "Something went wrong!". Null when the failure isn't recognized.
  String? devicesError;
  String? friendsError;

  /// True when we're rendering data from a previous successful load because the
  /// most recent refresh failed (e.g. relay unreachable). Drives a stale banner.
  bool devicesStale = false;
  bool friendsStale = false;

  Map<(double, double), Address> cachedAddresses = {};

  /// Turn a raw Rust/network error into something a user can act on.
  ///
  /// Find My auth flows through the relay device to mint Apple tokens
  /// (generate_validation_data -> MobileMe delegate login). When the relay is
  /// offline or its token is momentarily rejected, the errors surface as
  /// DeviceNotFound / UnauthorizedAccountError / DelegateLoginFailed. Those all
  /// mean the same thing to a user: we can't reach the paired Apple device.
  /// Everything else falls back to null so the generic message is used.
  static String? _describeFindMyError(Object e) {
    final s = e.toString();
    if (s.contains("DeviceNotFound") || s.contains("RelayError") || s.contains("FmipBridgeUnsupported")) {
      return "Can't reach your paired Apple device.\nFind My needs it to talk to Apple.";
    }
    if (s.contains("UnauthorizedAccountError") ||
        s.contains("DelegateLoginFailed") ||
        s.contains("TokenMissing")) {
      return "Apple rejected the sign-in from your paired device.\nIt may need to be unlocked or reconnected.";
    }
    if (s.contains("error sending request") ||
        s.contains("dns error") ||
        s.contains("ConnectionRefused") ||
        s.contains("SocketException") ||
        s.contains("Connection reset")) {
      return "No connection to Apple.\nCheck your network and try again.";
    }
    return null;
  }

  List<api.DartBeacon> cachedBeacons = [];
  DateTime? beaconCacheDate;

  Timer? myTimer;

  api.FindMyPhoneClientDefaultAnisetteProvider? fmipClient;

  @override
  void initState() {
    super.initState();
    if (widget.defaultFriend != null) {
      index.value = 1; // select friends tab
      tabController.index = 1;
    }
    if (widget.initialLocation != null) {
      // Opened from a received maps.apple.com link: drop a pin at the coords and center on it
      // once the map is ready.
      final loc = widget.initialLocation!;
      markers["dropped-pin"] = Marker(
        key: const ValueKey("dropped-pin"),
        point: loc,
        width: 30,
        height: 35,
        alignment: Alignment.topCenter,
        child: ClipShadowPath(
          clipper: const FindMyPinClipper(),
          shadow: const BoxShadow(color: Colors.black, blurRadius: 2),
          child: Container(
            color: Colors.white,
            child: const Center(
              child: Padding(
                padding: EdgeInsets.only(bottom: 5.0),
                child: Icon(Icons.location_on, color: Colors.red, size: 20),
              ),
            ),
          ),
        ),
      );
      completer.future.then((_) {
        if (!mounted) return;
        mapController.move(loc, 15);
      });
    }
    getLocations();

    myTimer = Timer.periodic(const Duration(seconds: 5), (timer) => getLocations());

    socket.socket.on("new-findmy-location", (data) {
      try {
        final friend = FindMyFriend.fromJson(data);
        Logger.info("Received new location for ${friend.handle?.address}");
        if ((friend.latitude ?? 0) == 0 && (friend.longitude ?? 0) == 0) return;
        final existingFriendIndex = friends.indexWhere((e) => e.handle?.uniqueAddressAndService == friend.handle?.uniqueAddressAndService);
        final existingFriend = existingFriendIndex == -1 ? null : friends[existingFriendIndex];
        if (existingFriend == null || existingFriend.status == null || friend.locatingInProgress || LocationStatus.values.indexOf(existingFriend.status!) <= LocationStatus.values.indexOf(friend.status ?? LocationStatus.legacy)) {
          Logger.info("Updating map for ${friend.handle?.address}");
          friends[existingFriendIndex] = friend;

          friendsWithLocation = friends.where((item) => (item.latitude ?? 0) != 0 && (item.longitude ?? 0) != 0).toList();
          friendsWithoutLocation = friends.where((item) => (item.latitude ?? 0) == 0 && (item.longitude ?? 0) == 0).toList();

          buildFriendMarker(friend);
          setState(() {});
        }
      } catch (_) {}
    });

    // // Allow users to refresh after 30sec
    // Future.delayed(const Duration(seconds: 30), () {
    //   if (mounted) {
    //     setState(() {
    //       canRefresh = true;
    //     });
    //   }
    // });
  }

  /// Fetches the FindMy data from the server.
  /// The toggles for refresh friends & devices are separate due to an inconsistency in the server API.
  /// As of v1.9.7 (server), the refresh devices endpoint doesn't return the devices data,
  /// however, the refresh friends endpoint does. The way this was coded assumes that the server
  /// will return the data for both endpoints. A server update will fix this, but for now,
  /// we will "patch" it by only "refreshing" devices when the user manually refreshes the data.
  void getLocations({bool refreshFriends = true, bool refreshDevices = true}) async {
    if (!(Platform.isLinux && !kIsWeb)) {
      LocationPermission granted = await Geolocator.checkPermission();
      if (granted == LocationPermission.denied) {
        granted = await Geolocator.requestPermission();
      }
      if (granted == LocationPermission.whileInUse || granted == LocationPermission.always) {
        Geolocator.getCurrentPosition(locationSettings: const LocationSettings(timeLimit: Duration(seconds: 30))).then((loc) {
          if (!mounted) return;
          if (ss.settings.lastLocation.value == null) {
            mapController.move(LatLng(loc.latitude, loc.longitude), 10);
          }
          ss.settings.lastLocation.value = "${loc.latitude},${loc.longitude}";
          ss.saveSettings();
          location = loc;
          buildLocationMarker(location!);
          if (!kIsDesktop && locationSub == null) {
            locationSub = Geolocator.getPositionStream().listen((event) {
              ss.settings.lastLocation.value = "${event.latitude},${event.longitude}";
              ss.saveSettings();
              setState(() {
                buildLocationMarker(event);
              });
            });
          }
          if (!refreshFriends) {
            mapController.move(LatLng(location!.latitude, location!.longitude), 10);
          }
        });
      }
    }

    // NOTE: We use the background `fmfd` (FindMyClient) path instead of a standalone
    // FindMyFriendsClient. Only `fmfd` holds the per-friend secure-location keys
    // (state.friend_secure_keys, populated by the inbound secureLocationsKeyUpdate IDS
    // handler) and wires the ECIES fetch+decrypt into refresh_background_following. A
    // standalone client created via makeFindMyFriends cannot decrypt friend locations.
    final fmfd = pushService.state!.icloudServices!.fmfd!;

    try {
      List<api.Follow> following;
      if (refreshFriends) {
        following = await api.refreshBackgroundFollowing(state: fmfd, config: pushService.state!.osConfig);
      } else {
        following = await api.getBackgroundFollowing(fmfd: fmfd);
      }
    
      friends = [];
      for (final e in following) {
        final loc = e.lastLocation;
        // Legacy (iOS 12) friend locations arrive with a server-provided `address` inline.
        // Secure-location (iOS 15+) friends arrive as raw coordinates only (address == null) —
        // Apple geocodes those on-device, so we reverse-geocode client-side to fill in the
        // list subtitle, mirroring the beacon path above. The map marker only needs lat/lon
        // and is unaffected. Cached by (lat,long) in the shared `cachedAddresses` map.
        String? longAddress = loc?.address?.formattedAddressLines?.join("\n");
        String? shortAddress = loc?.address != null
            ? "${loc?.address?.locality}, ${loc?.address?.stateCode ?? loc?.address?.countryCode}"
            : null;
        if (shortAddress == null && loc != null && loc.latitude != 0 && loc.longitude != 0) {
          final key = (loc.latitude, loc.longitude);
          Address? resolved = cachedAddresses[key];
          if (resolved == null) {
            try {
              final placemark = await pushService.reverseGeocode(loc.latitude, loc.longitude);
              if (placemark != null) {
                resolved = Address(
                  subAdministrativeArea: placemark.subAdministrativeArea,
                  label: placemark.thoroughfare ?? placemark.name,
                  streetAddress: placemark.thoroughfare,
                  country: placemark.country,
                  countryCode: placemark.isoCountryCode,
                  administrativeArea: placemark.administrativeArea,
                  streetName: placemark.thoroughfare,
                  formattedAddressLines: [
                    if (placemark.thoroughfare != null) placemark.thoroughfare!,
                    if (placemark.locality != null) placemark.locality!,
                    if (placemark.administrativeArea != null) placemark.administrativeArea!,
                  ],
                  locality: placemark.locality,
                  stateCode: placemark.administrativeArea?.substring(0, 2).toUpperCase(),
                  mapItemFullAddress: null,
                  fullThroroughfare: null,
                  areaOfInterest: [],
                );
                cachedAddresses[key] = resolved;
              }
            } catch (e, s) {
              Logger.warn("Friend geocoding failed", error: e, trace: s);
            }
          }
          if (resolved != null) {
            longAddress = resolved.formattedAddressLines.join("\n");
            shortAddress = "${resolved.locality}, ${resolved.stateCode ?? resolved.countryCode}";
          }
        }
        friends.add(FindMyFriend(
          latitude: loc?.latitude,
          longitude: loc?.longitude,
          longAddress: longAddress,
          shortAddress: shortAddress,
          title: null,
          subtitle: null,
          handle: Handle.findOne(addressAndService: Tuple2(e.invitationAcceptedHandles.first, "iMessage")) ?? Handle(address: e.invitationAcceptedHandles.first),
          lastUpdated: e.lastLocation?.timestamp != null ? DateTime.fromMillisecondsSinceEpoch(e.lastLocation!.timestamp) : null,
          status: null,
          locatingInProgress: false,
          id: e.id,
        ));
      }

      friendsWithLocation = friends.where((item) => (item.latitude ?? 0) != 0 && (item.longitude ?? 0) != 0).toList();
      friendsWithoutLocation = friends.where((item) => (item.latitude ?? 0) == 0 && (item.longitude ?? 0) == 0).toList();

      for (FindMyFriend e in friendsWithLocation) {
        buildFriendMarker(e);
      }
      setState(() {
        fetching2 = false;
        refreshing2 = false;
        friendsError = null;
        friendsStale = false;
      });
      if (widget.defaultFriend != null) {
        var friend = friends.firstWhereOrNull((friend) => friend.id == widget.defaultFriend);
        widget.defaultFriend = null;
        if (friend != null) {
          if (context.isPhone) {
            await panelController.close();
          }
          await completer.future;

          await api.selectBackgroundFriend(fmfd: pushService.state!.icloudServices!.fmfd!, friend: friend.id);


          if (friend.latitude != null) {

            final marker = markers.values.firstWhere(
                (e) => (e.key as ValueKey?)?.value == "friend-${friend.handle?.uniqueAddressAndService}");
            popupController.showPopupsOnlyFor([marker]);
            mapController.move(LatLng(friend.latitude!, friend.longitude!), 10);

          }
        }
      }
    } catch (e, s) {
      Logger.error("Failed to parse FindMy Friends location data!", error: e, trace: s);
      // Don't throw away friends we already loaded successfully. A transient
      // relay/token blip should degrade to "stale" rather than blanking the
      // list — only a genuine cold start (nothing cached) shows the error.
      setState(() {
        friendsError = _describeFindMyError(e);
        if (friends.isNotEmpty) {
          friendsStale = true;
          fetching2 = false;
        } else {
          fetching2 = null;
        }
        refreshing2 = false;
      });
      return;
    }

    var isNewi = fmipClient == null;

    try {
      // NOTE: makeFindMyPhone used to be called outside this try. Its constructor
      // runs initClient, which needs an MME token and therefore the relay — so on a
      // cold start with the relay offline it threw, the exception escaped this whole
      // method, and the devices tab was left on `fetching == true` forever (a
      // permanent "Getting FindMy data..." spinner). Constructing inside the try
      // means that failure is reported like any other.
      fmipClient ??= await api.makeFindMyPhone(
        config: pushService.state!.osConfig,
        path: pushService.statePath,
        aps: pushService.state!.conn,
        anisette: pushService.state!.anisette,
        provider: pushService.state!.icloudServices!.tokenProvider,
      );

      if (refreshDevices && !isNewi) {
        await api.refreshDevices(config: pushService.state!.osConfig, client: fmipClient!);
      }

      var following = await api.getDevices(client: fmipClient!);
    
      var devices = following
          .map((e) => 
            FindMyDevice(
              deviceModel: e.deviceModel, 
              lowPowerMode: e.lowPowerMode, 
              passcodeLength: e.passcodeLength, 
              itemGroup: null, 
              id: e.id, 
              batteryStatus: e.batteryStatus, 
              audioChannels: [], 
              lostModeCapable: e.lostModeCapable, 
              snd: null, 
              batteryLevel: e.batteryLevel, 
              locationEnabled: e.locationEnabled, 
              isConsideredAccessory: e.isConsideredAccessory ?? false, 
              address: null, 
              location: e.location != null ? Location(
                positionType: e.location!.positionType, 
                verticalAccuracy: e.location!.verticalAccuracy.round(), 
                longitude: e.location!.longitude, 
                floorLevel: e.location!.floorLevel, 
                isInaccurate: e.location!.isInaccurate, 
                isOld: e.location!.isOld, 
                horizontalAccuracy: e.location!.horizontalAccuracy, 
                latitude: e.location!.latitude, 
                timeStamp: e.location!.timestamp, 
                altitude: e.location!.altitude.round(), 
                locationFinished: e.location!.locationFinished
                ) : null, 
              modelDisplayName: e.modelDisplayName, 
              deviceColor: e.deviceColor, 
              activationLocked: e.activationLocked, 
              rm2State: e.rm2State, 
              locFoundEnabled: e.locFoundEnabled, 
              nwd: e.nwd, 
              deviceStatus: e.deviceStatus, 
              remoteWipe: null, 
              fmlyShare: e.fmlyShare, 
              thisDevice: e.thisDevice, 
              lostDevice: null, 
              lostModeEnabled: e.lostModeEnabled, 
              deviceDisplayName: e.deviceDisplayName, 
              safeLocations: null, 
              name: e.name, 
              canWipeAfterLock: e.canWipeAfterLock, 
              isMac: e.isMac, 
              rawDeviceModel: e.rawDeviceModel, 
              baUuid: e.baUuid, 
              trackingInfo: null,
              features: e.features, 
              deviceDiscoveryId: e.deviceDiscoveryId, 
              prsId: null, 
              scd: e.scd, 
              locationCapable: e.locationCapable, 
              remoteLock: null, 
              wipeInProgress: e.wipeInProgress, 
              darkWake: e.darkWake, 
              deviceWithYou: e.deviceWithYou, 
              maxMsgChar: e.maxMsgChar, 
              deviceClass: e.deviceClass, 
              crowdSourcedLocation: null, 
              role: null,
              lostModeMetadata: null
            )
          )
          .toList().cast<FindMyDevice>();
      

      if (beaconCacheDate == null || DateTime.now().difference(beaconCacheDate!).inMinutes > 3) {
        isInClique = await api.isInClique(keychain: pushService.state!.icloudServices!.keychain!);
        try {
          cachedBeacons = isInClique ? await api.getBeaconItems(items: pushService.state!.icloudServices!.fmfd!) : [];
        } catch (e, s) {
          // used for PCS key missing catching after we reset the clique.
          Logger.error("Failed to fetch beacon data", error: e, trace: s);
        }
        beaconCacheDate = DateTime.now();
        for (var cached in cachedBeacons) {
          if (cached.lastReport == null) continue;
          try {
            var placemark = await pushService.reverseGeocode(cached.lastReport!.lat, cached.lastReport!.long);
            if (placemark != null) {
              cachedAddresses[(cached.lastReport!.lat, cached.lastReport!.long)] = Address(
                subAdministrativeArea: placemark.subAdministrativeArea,
                label: placemark.thoroughfare ?? placemark.name,
                streetAddress: placemark.thoroughfare,
                country: placemark.country,
                countryCode: placemark.isoCountryCode,
                administrativeArea: placemark.administrativeArea,
                streetName: placemark.thoroughfare,
                formattedAddressLines: [
                  if (placemark.thoroughfare != null)
                  placemark.thoroughfare!,
                  if (placemark.locality != null)
                  placemark.locality!,
                  if (placemark.administrativeArea != null)
                  placemark.administrativeArea!,
                ],
                locality: placemark.locality,
                stateCode: placemark.administrativeArea?.substring(0, 2).toUpperCase(),
                mapItemFullAddress: null,
                fullThroroughfare: null,
                areaOfInterest: [],
              );
            }
          } catch (e, s) {
            Logger.warn("Geocoding failed", error: e, trace: s);
          }
        }
      }
      for (api.DartBeacon e in cachedBeacons) {
        var location = e.lastReport != null ? Location(
            positionType: null, 
            verticalAccuracy: e.lastReport!.confidence, 
            longitude: e.lastReport!.long, 
            floorLevel: null, 
            isInaccurate: null, 
            isOld: null, 
            horizontalAccuracy: e.lastReport!.horizontalAccuracy.toDouble(), 
            latitude: e.lastReport!.lat, 
            timeStamp: api.systemtimeToMillis(time: e.lastReport!.timestamp), 
            altitude: null, 
            locationFinished: true,
            ) : null;
        if (e.productId == -1) {
          var existingDevice = devices.firstWhereOrNull((d) => d.name == e.naming.name && !d.isConsideredAccessory);
          if (existingDevice == null || e.lastReport == null) continue;
          if (existingDevice.location?.timeStamp != null && api.systemtimeToMillis(time: e.lastReport!.timestamp) < existingDevice.location!.timeStamp!) continue; // report is older
          existingDevice.location = location;
          continue; // this is an iDevice
        }
        devices.add(FindMyDevice(
          deviceModel: e.model, 
          lowPowerMode: false, 
          passcodeLength: null, 
          itemGroup: null, 
          id: e.id, 
          batteryStatus: null, 
          audioChannels: [], 
          lostModeCapable: true, 
          snd: null, 
          batteryLevel: e.batteryLevel?.toDouble(), 
          locationEnabled: true, 
          isConsideredAccessory: true, 
          address: e.lastReport == null ? null : cachedAddresses[(e.lastReport!.lat, e.lastReport!.long)], 
          location: location, 
          modelDisplayName: null, 
          deviceColor: null, 
          activationLocked: false, 
          rm2State: null, 
          locFoundEnabled: false, 
          nwd: null, 
          deviceStatus: null, 
          remoteWipe: null, 
          fmlyShare: null, 
          thisDevice: false, 
          lostDevice: null, 
          lostModeEnabled: false, 
          deviceDisplayName: e.naming.name, 
          safeLocations: null, 
          name: e.naming.name, 
          canWipeAfterLock: false, 
          isMac: false, 
          rawDeviceModel: e.model,
          baUuid: null,
          trackingInfo: null,
          features: null,
          deviceDiscoveryId: null,
          prsId: null, 
          scd: null,
          locationCapable: null,
          remoteLock: null, 
          wipeInProgress: null,
          darkWake: null,
          deviceWithYou: false,
          maxMsgChar: null,
          deviceClass: null,
          crowdSourcedLocation: null, 
          role: {
            "emoji": e.naming.emoji,
            "sharingId": e.shared?.shareId,
            "sharingActive": e.shared?.acceptanceState,
            "sharingName": e.shared?.ownerHandle != null ? RustPushBBUtils.rustHandleToBB(e.shared!.ownerHandle).displayName : null,
          },
          lostModeMetadata: null
        ));
      }

      this.devices = devices;

      for (FindMyDevice e in devices.where((e) => e.location?.latitude != null && e.location?.longitude != null)) {
          markers[e.id ?? randomString(6)] = Marker(
            key: ValueKey('device-${e.id ?? randomString(6)}'),
            point: LatLng(e.location!.latitude!, e.location!.longitude!),
            width: 30,
            height: 35,
            child: ClipShadowPath(
              clipper: const FindMyPinClipper(),
              shadow: const BoxShadow(
                color: Colors.black,
                blurRadius: 2,
              ),
              child: Container(
                color: Colors.white,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 5.0),
                    child: e.role?['emoji'] != null
                        ? Text(e.role!['emoji'],
                            style: context.theme.textTheme.bodyLarge!.copyWith(fontFamily: 'Apple Color Emoji'))
                        : Icon(
                            (e.isMac ?? false)
                                ? CupertinoIcons.desktopcomputer
                                : e.isConsideredAccessory
                                    ? CupertinoIcons.headphones
                                    : CupertinoIcons.device_phone_portrait,
                            color: Colors.black,
                            size: 20,
                          ),
                  ),
                ),
              ),
            ),
            alignment: Alignment.topCenter,
          );
        }
      setState(() {
        fetching = false;
        refreshing = false;
        devicesError = null;
        devicesStale = false;
      });
    } catch (e, s) {
      Logger.error("Failed to parse FindMy Devices location data!", error: e, trace: s);
      // Same policy as the friends tab: keep the last known device list rather
      // than discarding it. Previously any refresh failure set fetching = null,
      // which blanked an already-populated list.
      setState(() {
        devicesError = _describeFindMyError(e);
        if (devices.isNotEmpty) {
          devicesStale = true;
          fetching = false;
        } else {
          fetching = null;
        }
        refreshing = false;
      });
      return;
    }
    

    // // Call the FindMy Friends refresh anyways so that new data comes through the socket
    // if (!refreshFriends) {
    //   http.refreshFindMyFriends();
    // } else {
    //   setState(() {
    //     canRefresh = false;
    //   });
    //   // Allow users to refresh after 30sec
    //   Future.delayed(const Duration(seconds: 30), () {
    //     if (mounted) {
    //       setState(() {
    //         canRefresh = true;
    //       });
    //     }
    //   });
    // }
  }

  void buildFriendMarker(FindMyFriend friend) {
    markers[friend.handle?.uniqueAddressAndService ?? randomString(6)] = Marker(
      key: ValueKey('friend-${friend.handle?.uniqueAddressAndService ?? randomString(6)}'),
      point: LatLng(friend.latitude!, friend.longitude!),
      width: 35,
      height: 35,
      child: Container(
        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(3),
            child:
            ContactAvatarWidget(editable: false, handle: friend.handle ?? Handle(address: friend.title ?? "Unknown")),
          ),
        ),
      ),
      alignment: Alignment.topCenter,
    );
  }

  void buildLocationMarker(Position pos) {
    markers['current'] = Marker(
      key: const ValueKey('current'),
      point: LatLng(pos.latitude, pos.longitude),
      width: 25,
      height: 55,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (pos.heading.isFinite)
            Transform.rotate(
              angle: pos.heading,
              child: ClipPath(
                clipper: const FindMyLocationClipper(),
                child: Container(
                  width: 25,
                  height: 55,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: AlignmentDirectional.center,
                      end: Alignment.topCenter,
                      colors: [context.theme.colorScheme.primary, context.theme.colorScheme.primary.withAlpha(50)],
                    ),
                  ),
                ),
              ),
            ),
          Container(
            width: 25,
            height: 25,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
            ),
            padding: const EdgeInsets.all(5),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: context.theme.colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
      alignment: Alignment.topCenter,
    );
  }

  Future<void> deleteShared(FindMyDevice item) async {
    await api.deleteBeaconShare(items: pushService.state!.icloudServices!.fmfd!, share: item.role!['sharingId']!);
    setState(() {
      devices.remove(item);
    });
    beaconCacheDate = null;
  }

  Future<void> addShared(FindMyDevice item) async {
    await api.acceptBeaconShare(items: pushService.state!.icloudServices!.fmfd!, share: item.role!['sharingId']!);
    setState(() {
      devices.remove(item); // it'll go away anyways because it has no location
    });
    beaconCacheDate = null;
    getLocations();
  }

  @override
  void dispose() {
    locationSub?.cancel();
    mapController.dispose();
    popupController.dispose();
    tabController.dispose();
    myTimer?.cancel();
    // TODO
    socket.socket.off("new-findmy-location");
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final devicesWithLocation = devices
        .where(
            (item) => item.location?.latitude != null && !item.isConsideredAccessory)
        .toList();
    final itemsWithLocation = devices
        .where(
            (item) => (item.location?.latitude != null || item.role?["sharingActive"] == 0) && item.isConsideredAccessory)
        .toList();
    final withoutLocation =
        devices.where((item) => item.location?.latitude == null && item.role?["sharingActive"] != 0).toList();
    final devicesBodySlivers = [
      SliverList(
        delegate: SliverChildListDelegate([
          if (fetching == null || fetching == true || (fetching == false && devices.isEmpty))
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 100),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text(
                        fetching == null
                            ? (devicesError ?? "Something went wrong!")
                            : fetching == false
                                ? "You have no devices."
                                : "Getting FindMy data...",
                        textAlign: TextAlign.center,
                        style: context.theme.textTheme.labelLarge,
                      ),
                    ),
                    if (fetching == true) buildProgressIndicator(context, size: 15),
                    // The error state used to be terminal — no way to recover without
                    // backing out of the page and re-entering. Offer a retry in place.
                    if (fetching == null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: TextButton(
                          onPressed: refreshing
                              ? null
                              : () {
                                  setState(() {
                                    refreshing = true;
                                    fetching = true;
                                  });
                                  getLocations(refreshDevices: true, refreshFriends: false);
                                },
                          child: Text(refreshing ? "Retrying..." : "Retry"),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          // Serving a cached device list because the latest refresh failed.
          if (devicesStale && devices.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
              child: Row(
                children: [
                  Icon(iOS ? CupertinoIcons.exclamationmark_circle : Icons.warning_amber,
                      size: 16, color: context.theme.colorScheme.outline),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      devicesError == null
                          ? "Showing last known locations — couldn't refresh."
                          : "Showing last known locations. ${devicesError!.replaceAll("\n", " ")}",
                      style: context.theme.textTheme.bodySmall!.copyWith(color: context.theme.colorScheme.outline),
                    ),
                  ),
                ],
              ),
            ),
          if (devicesWithLocation.isNotEmpty)
            SettingsHeader(iosSubtitle: iosSubtitle, materialSubtitle: materialSubtitle, text: "Devices"),
          if (devicesWithLocation.isNotEmpty)
            SettingsSection(
              backgroundColor: tileColor,
              children: [
                Material(
                  color: Colors.transparent,
                  child: ListView.builder(
                    physics: const NeverScrollableScrollPhysics(),
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    findChildIndexCallback: (key) => findChildIndexByKey(devicesWithLocation, key, (item) => item.address?.uniqueValue),
                    itemBuilder: (context, i) {
                      final item = devicesWithLocation[i];
                      return ListTile(
                        key: ValueKey(item.address?.uniqueValue),
                        mouseCursor: MouseCursor.defer,
                        title: Text(ss.settings.redactedMode.value ? "Device" : (item.name ?? "Unknown Device")),
                        onTap: item.location?.latitude != null && item.location?.longitude != null
                            ? () async {
                                if (context.isPhone) {
                                  await panelController.close();
                                }
                                await completer.future;
                                final marker = markers.values.firstWhere((e) =>
                                    e.point.latitude == item.location?.latitude &&
                                    e.point.longitude == item.location?.longitude);
                                popupController.showPopupsOnlyFor([marker]);
                                mapController.move(LatLng(item.location!.latitude!, item.location!.longitude!), 10);
                              }
                            : null,
                        trailing: item.location?.latitude != null && item.location?.longitude != null ? ButtonTheme(
                          minWidth: 1,
                          child: TextButton(
                            style: TextButton.styleFrom(
                              shape: const CircleBorder(),
                              backgroundColor: context.theme.colorScheme.primaryContainer,
                            ),
                            onPressed: () async {
                              await MapsLauncher.launchCoordinates(item.location!.latitude!, item.location!.longitude!);
                            },
                            child: const Icon(
                                Icons.directions,
                                size: 20
                            ),
                          ),
                        ) : null,
                        onLongPress: () async {
                          const encoder = JsonEncoder.withIndent("     ");
                          final str = encoder.convert(item.toJson());
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text(
                                "Raw FindMy Data",
                                style: context.theme.textTheme.titleLarge,
                              ),
                              backgroundColor: context.theme.colorScheme.properSurface,
                              content: SizedBox(
                                width: ns.width(context) * 3 / 5,
                                height: context.height * 1 / 4,
                                child: Container(
                                  padding: const EdgeInsets.all(10.0),
                                  decoration: BoxDecoration(
                                      color: context.theme.colorScheme.background,
                                      borderRadius: const BorderRadius.all(Radius.circular(10))),
                                  child: SingleChildScrollView(
                                    child: SelectableText(
                                      str,
                                      style: context.theme.textTheme.bodyLarge,
                                    ),
                                  ),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  child: Text("Close",
                                      style: context.theme.textTheme.bodyLarge!
                                          .copyWith(color: context.theme.colorScheme.primary)),
                                  onPressed: () => Navigator.of(context).pop(),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                    itemCount: devicesWithLocation.length,
                  ),
                ),
              ],
            ),
          if (itemsWithLocation.isNotEmpty || !isInClique)
            SettingsHeader(iosSubtitle: iosSubtitle, materialSubtitle: materialSubtitle, text: "Items"),
          if (!isInClique)
          Obx(() => SettingsSection(
            backgroundColor: tileColor,
            children: [
              SettingsTile(
                title: "Show Airtags",
                onTap: () async {
                  if (pushService.state?.icloudServices?.keychain == null) {
                    showSnackbar("Relog required!", "Relog required to use Backup! Relog in Settings -> Reconfigure");
                    return;
                  }
                  if (!await pushService.joinClique()) return;
                  beaconCacheDate = null;
                  getLocations();
                },
                trailing: const NextButton(),
              ),
            ]
        )),
          if (itemsWithLocation.isNotEmpty)
            SettingsSection(
              backgroundColor: tileColor,
              children: [
                Material(
                  color: Colors.transparent,
                  child: ListView.builder(
                    physics: const NeverScrollableScrollPhysics(),
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    findChildIndexCallback: (key) => findChildIndexByKey(itemsWithLocation, key, (item) => item.id ?? randomString(6)),
                    itemBuilder: (context, i) {
                      final item = itemsWithLocation[i];
                      var tile = ListTile(
                        key: ValueKey(item.id ?? randomString(6)),
                        title: Text(ss.settings.redactedMode.value ? "Item" : (item.name ?? "Unknown Item")),
                        subtitle: item.role?["sharingActive"] == 0 ? Column(
                          children: [
                            Text("${item.role?["sharingName"]} wants to share this item with you."),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: context.theme.colorScheme.outline.withAlpha(64),
                                    padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 13),
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    elevation: 0.0,
                                    minimumSize: Size.zero,
                                  ),
                                  onPressed: () async {
                                    pushService.wrapPromise(deleteShared(item), "Removing...");
                                  },
                                  child: Text("Don't Add", style: context.theme.textTheme.titleMedium),
                                ),
                                const SizedBox(width: 10),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: context.theme.colorScheme.primary,
                                    padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 13),
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    elevation: 0.0,
                                    minimumSize: Size.zero,
                                  ),
                                  onPressed: () async {
                                    pushService.wrapPromise(addShared(item), "Adding...");
                                  },
                                  child: Text("Add", style: context.theme.textTheme.titleMedium?.apply(color: context.theme.colorScheme.onPrimary)),
                                ),
                              ],
                            )
                          ],
                        )
                          : Text(ss.settings.redactedMode.value ? "Location" : (item.address?.label ?? item.address?.mapItemFullAddress ?? "No location found")),
                        trailing: item.location?.latitude != null && item.location?.longitude != null ? ButtonTheme(
                          minWidth: 1,
                          child: TextButton(
                            style: TextButton.styleFrom(
                              shape: const CircleBorder(),
                              backgroundColor: context.theme.colorScheme.primaryContainer,
                            ),
                            onPressed: () async {
                              await MapsLauncher.launchCoordinates(item.location!.latitude!, item.location!.longitude!);
                            },
                            child: const Icon(
                                Icons.directions,
                                size: 20
                            ),
                          ),
                        ) : null,
                        onTap: item.location?.latitude != null && item.location?.longitude != null
                            ? () async {
                                if (context.isPhone) {
                                  await panelController.close();
                                }
                                await completer.future;
                                final marker = markers.values.firstWhere((e) =>
                                      e.point.latitude == item.location?.latitude &&
                                      e.point.longitude == item.location?.longitude);
                                  popupController.showPopupsOnlyFor([marker]);
                                mapController.move(LatLng(item.location!.latitude!, item.location!.longitude!), 10);
                              }
                            : null,
                        onLongPress: () async {
                          const encoder = JsonEncoder.withIndent("     ");
                          final str = encoder.convert(item.toJson());
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text(
                                "Raw FindMy Data",
                                style: context.theme.textTheme.titleLarge,
                              ),
                              backgroundColor: context.theme.colorScheme.properSurface,
                              content: SizedBox(
                                width: ns.width(context) * 3 / 5,
                                height: context.height * 1 / 4,
                                child: Container(
                                  padding: const EdgeInsets.all(10.0),
                                  decoration: BoxDecoration(
                                      color: context.theme.colorScheme.background,
                                      borderRadius: const BorderRadius.all(Radius.circular(10))),
                                  child: SingleChildScrollView(
                                    child: SelectableText(
                                      str,
                                      style: context.theme.textTheme.bodyLarge,
                                    ),
                                  ),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  child: Text("Close",
                                      style: context.theme.textTheme.bodyLarge!
                                          .copyWith(color: context.theme.colorScheme.primary)),
                                  onPressed: () => Navigator.of(context).pop(),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                      if (item.role?['sharingId'] != null) {
                        return wrapDelete(tile, (context) => deleteShared(item));
                      }
                      return tile;
                    },
                    itemCount: itemsWithLocation.length,
                  ),
                ),
              ],
            ),
          if (withoutLocation.isNotEmpty)
            SettingsHeader(iosSubtitle: iosSubtitle, materialSubtitle: materialSubtitle, text: "Unknown Location"),
          if (withoutLocation.isNotEmpty)
            SettingsSection(
              backgroundColor: tileColor,
              children: [
                Material(
                  color: Colors.transparent,
                  child: ExpansionTile(
                      shape: const RoundedRectangleBorder(side: BorderSide(color: Colors.transparent)),
                      title: const Text("Devices without locations"),
                      children: withoutLocation
                          .map((item) {
                            var tile = ListTile(
                                title: Text(ss.settings.redactedMode.value ? "Device" : (item.name ?? "Unknown Device")),
                                subtitle: Text(ss.settings.redactedMode.value ? "Location" : (item.address?.label ?? item.address?.mapItemFullAddress ?? "No location found")),
                                onTap: item.location?.latitude != null && item.location?.longitude != null
                                    ? () async {
                                        if (context.isPhone) {
                                          await panelController.close();
                                        }
                                        await completer.future;
                                        final marker = markers.values.firstWhere((e) =>
                                            e.point.latitude == item.location?.latitude &&
                                            e.point.longitude == item.location?.longitude);
                                        popupController.showPopupsOnlyFor([marker]);
                                        mapController.move(
                                            LatLng(item.location!.latitude!, item.location!.longitude!), 10);
                                      }
                                    : null,
                                onLongPress: () async {
                                  const encoder = JsonEncoder.withIndent("     ");
                                  final str = encoder.convert(item.toJson());
                                  showDialog(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: Text(
                                        "Raw FindMy Data",
                                        style: context.theme.textTheme.titleLarge,
                                      ),
                                      backgroundColor: context.theme.colorScheme.properSurface,
                                      content: SizedBox(
                                        width: ns.width(context) * 3 / 5,
                                        height: context.height * 1 / 4,
                                        child: Container(
                                          padding: const EdgeInsets.all(10.0),
                                          decoration: BoxDecoration(
                                              color: context.theme.colorScheme.background,
                                              borderRadius: const BorderRadius.all(Radius.circular(10))),
                                          child: SingleChildScrollView(
                                            child: SelectableText(
                                              str,
                                              style: context.theme.textTheme.bodyLarge,
                                            ),
                                          ),
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                          child: Text("Close",
                                              style: context.theme.textTheme.bodyLarge!
                                                  .copyWith(color: context.theme.colorScheme.primary)),
                                          onPressed: () => Navigator.of(context).pop(),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              );
                              if (item.role?['sharingId'] != null) {
                                return wrapDelete(tile, (context) => deleteShared(item));
                              }
                              return tile;
                            })
                          .toList()),
                ),
              ],
            ),
        ]),
      ),
    ];

    final friendsBodySlivers = [
      SliverList(
        delegate: SliverChildListDelegate([
          if (fetching2 == null || fetching2 == true || (fetching2 == false && friends.isEmpty))
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 100),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text(
                        fetching2 == null
                            ? (friendsError ?? "Something went wrong!")
                            : fetching2 == false
                                ? "You have no friends."
                                : "Getting FindMy data...",
                        textAlign: TextAlign.center,
                        style: context.theme.textTheme.labelLarge,
                      ),
                    ),
                    if (fetching2 == true) buildProgressIndicator(context, size: 15),
                    if (fetching2 == null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: TextButton(
                          onPressed: refreshing2
                              ? null
                              : () {
                                  setState(() {
                                    refreshing2 = true;
                                    fetching2 = true;
                                  });
                                  getLocations(refreshDevices: false, refreshFriends: true);
                                },
                          child: Text(refreshing2 ? "Retrying..." : "Retry"),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          // Serving a cached friends list because the latest refresh failed.
          if (friendsStale && friends.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
              child: Row(
                children: [
                  Icon(iOS ? CupertinoIcons.exclamationmark_circle : Icons.warning_amber,
                      size: 16, color: context.theme.colorScheme.outline),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      friendsError == null
                          ? "Showing last known locations — couldn't refresh."
                          : "Showing last known locations. ${friendsError!.replaceAll("\n", " ")}",
                      style: context.theme.textTheme.bodySmall!.copyWith(color: context.theme.colorScheme.outline),
                    ),
                  ),
                ],
              ),
            ),
          if (friendsWithLocation.isNotEmpty)
            SettingsHeader(iosSubtitle: iosSubtitle, materialSubtitle: materialSubtitle, text: "Friends"),
          if (friendsWithLocation.isNotEmpty)
            SettingsSection(
              backgroundColor: tileColor,
              children: [
                Material(
                  color: Colors.transparent,
                  child: ListView.builder(
                    physics: const NeverScrollableScrollPhysics(),
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    findChildIndexCallback: (key) => findChildIndexByKey(friendsWithLocation, key, (item) => item.handle?.uniqueAddressAndService),
                    itemBuilder: (context, i) {
                      final item = friendsWithLocation[i];
                      return ListTile(
                        key: ValueKey(item.handle?.uniqueAddressAndService),
                        leading: ContactAvatarWidget(handle: item.handle),
                        title: Text(item.handle?.displayName ?? item.title ?? "Unknown Friend"),
                        subtitle: Text(ss.settings.redactedMode.value ? "Location" : ("${item.shortAddress ?? "No location found"}${item.lastUpdated == null || item.status == LocationStatus.live ? "" : "\nLast updated ${buildDate(item.lastUpdated)}"}")),
                        trailing: item.latitude != null && item.longitude != null ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (item.status == LocationStatus.live)
                              const Icon(CupertinoIcons.largecircle_fill_circle),
                            if (item.locatingInProgress)
                              buildProgressIndicator(context),
                            ButtonTheme(
                              minWidth: 1,
                              child: TextButton(
                                style: TextButton.styleFrom(
                                  shape: const CircleBorder(),
                                  backgroundColor: context.theme.colorScheme.primaryContainer,
                                ),
                                onPressed: () async {
                                  await MapsLauncher.launchCoordinates(item.latitude!, item.longitude!);
                                },
                                child: const Icon(
                                    Icons.directions,
                                    size: 20
                                ),
                              ),
                            ),
                          ],
                        ) : null,
                        onTap: () async {
                          if (context.isPhone) {
                            await panelController.close();
                          }
                          await completer.future;
                          final marker = markers.values.firstWhere(
                              (e) => e.point.latitude == item.latitude && e.point.longitude == item.longitude);
                          popupController.showPopupsOnlyFor([marker]);
                          mapController.move(LatLng(item.latitude!, item.longitude!), 10);
                        },
                        onLongPress: () async {
                          const encoder = JsonEncoder.withIndent("     ");
                          final str = encoder.convert(item.toJson());
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text(
                                "Raw FindMy Data",
                                style: context.theme.textTheme.titleLarge,
                              ),
                              backgroundColor: context.theme.colorScheme.properSurface,
                              content: SizedBox(
                                width: ns.width(context) * 3 / 5,
                                height: context.height / 2,
                                child: Container(
                                  padding: const EdgeInsets.all(10.0),
                                  decoration: BoxDecoration(
                                      color: context.theme.colorScheme.background,
                                      borderRadius: const BorderRadius.all(Radius.circular(10))),
                                  child: SingleChildScrollView(
                                    child: SelectableText(
                                      str,
                                      style: context.theme.textTheme.bodyLarge,
                                    ),
                                  ),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  child: Text("Close",
                                      style: context.theme.textTheme.bodyLarge!
                                          .copyWith(color: context.theme.colorScheme.primary)),
                                  onPressed: () => Navigator.of(context).pop(),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                    itemCount: friendsWithLocation.length,
                  ),
                ),
              ],
            ),
          if (friendsWithoutLocation.isNotEmpty)
            SettingsHeader(iosSubtitle: iosSubtitle, materialSubtitle: materialSubtitle, text: "Unknown Location"),
          if (friendsWithoutLocation.isNotEmpty)
            SettingsSection(
              backgroundColor: tileColor,
              children: [
                Material(
                  color: Colors.transparent,
                  child: ExpansionTile(
                      shape: const RoundedRectangleBorder(side: BorderSide(color: Colors.transparent)),
                      title: const Text("Friends without locations"),
                      children: friendsWithoutLocation
                          .map((item) => ListTile(
                                mouseCursor: MouseCursor.defer,
                                leading: ContactAvatarWidget(handle: item.handle),
                                title: Text(item.handle?.displayName ?? item.title ?? "Unknown Friend"),
                                subtitle: Text(ss.settings.redactedMode.value ? "Location" : (item.longAddress ?? "No location found")),
                                onTap: () async {
                                  await api.selectBackgroundFriend(fmfd: pushService.state!.icloudServices!.fmfd!, friend: item.id);
                                },
                                onLongPress: () async {
                                  const encoder = JsonEncoder.withIndent("     ");
                                  final str = encoder.convert(item.toJson());
                                  showDialog(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: Text(
                                        "Raw FindMy Data",
                                        style: context.theme.textTheme.titleLarge,
                                      ),
                                      backgroundColor: context.theme.colorScheme.properSurface,
                                      content: SizedBox(
                                        width: ns.width(context) * 3 / 5,
                                        height: context.height * 1 / 4,
                                        child: Container(
                                          padding: const EdgeInsets.all(10.0),
                                          decoration: BoxDecoration(
                                              color: context.theme.colorScheme.background,
                                              borderRadius: const BorderRadius.all(Radius.circular(10))),
                                          child: SingleChildScrollView(
                                            child: SelectableText(
                                              str,
                                              style: context.theme.textTheme.bodyLarge,
                                            ),
                                          ),
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                          child: Text("Close",
                                              style: context.theme.textTheme.bodyLarge!
                                                  .copyWith(color: context.theme.colorScheme.primary)),
                                          onPressed: () => Navigator.of(context).pop(),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ))
                          .toList()),
                ),
              ],
            ),
        ]),
      ),
    ];

    return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          systemNavigationBarColor: ss.settings.immersiveMode.value
              ? Colors.transparent
              : context.theme.colorScheme.background, // navigation bar color
          systemNavigationBarIconBrightness: context.theme.colorScheme.brightness.opposite,
          statusBarColor: Colors.transparent, // status bar color
          statusBarIconBrightness: Brightness.dark,
        ),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            if (context.isPhone) {
              return buildNormal(context, devicesBodySlivers, friendsBodySlivers);
            }
            return buildTabletLayout(context, devicesBodySlivers, friendsBodySlivers);
          },
        ));
  }

  Widget buildTabletLayout(BuildContext context, List<SliverList> devicesBodySlivers, List<SliverList> friendsBodySlivers) {
    return Obx(
      () => Scaffold(
        backgroundColor: context.theme.colorScheme.background.themeOpacity(context),
        body: Stack(
          children: [
            Row(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(minWidth: 300, maxWidth: max(300, min(500, ns.width(context) / 3))),
                  child: Container(
                    width: 500,
                  ),
                ),
                Expanded(
                  child: Stack(
                    children: [
                      buildMap(),
                      if (!samsung && canRefresh)
                        Positioned(
                          top: 10 + (kIsDesktop ? appWindow.titleBarHeight : MediaQuery.of(context).padding.top),
                          right: 20,
                          child: Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Theme.of(context).colorScheme.properSurface.withOpacity(0.9),
                            ),
                            child: Container(
                              width: 48,
                              child: refreshing || refreshing2
                                  ? buildProgressIndicator(context)
                                  : IconButton(
                                      iconSize: 22,
                                      icon: Icon(iOS ? CupertinoIcons.arrow_counterclockwise : Icons.refresh,
                                          color: context.theme.colorScheme.onBackground, size: 22),
                                      onPressed: () {
                                        setState(() {
                                          refreshing = true;
                                          refreshing2 = true;
                                        });
                                        getLocations();
                                      },
                                    ),
                            ),
                          ),
                        ),
                      if (kIsDesktop)
                        SizedBox(
                          height: appWindow.titleBarHeight,
                          child: AbsorbPointer(
                            child: Row(children: [
                              Expanded(child: Container()),
                              ClipRect(
                                child: BackdropFilter(
                                  filter: ImageFilter.blur(sigmaY: 2, sigmaX: 2),
                                  child: Container(
                                      height: appWindow.titleBarHeight,
                                      width: appWindow.titleBarButtonSize.width * 3,
                                      color: context.theme.colorScheme.properSurface.withOpacity(0.5)),
                                ),
                              ),
                            ]),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            ConstrainedBox(
              constraints: BoxConstraints(minWidth: 300, maxWidth: max(300, min(500, ns.width(context) / 3))),
              child: Column(
                children: [
                  if (!samsung)
                    Container(
                      child: Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            margin: const EdgeInsets.symmetric(horizontal: 8),
                            child: buildBackButton(context),
                          ),
                          Expanded(child: Text("Find My", style: context.theme.textTheme.titleLarge)),
                        ],
                      ),
                    ),
                  if (!samsung) buildDesktopTabBar(),
                  Expanded(
                    child: Container(
                      width: 500,
                      child: TabBarView(
                        controller: tabController,
                        children: [
                          ScrollbarWrapper(
                            controller: controller1,
                            child: CustomScrollView(
                              controller: controller1,
                              slivers: [
                                if (samsung) buildSamsungAppBar(context, "FindMy Devices"),
                                if (ss.settings.skin.value != Skins.Samsung) ...devicesBodySlivers,
                                if (ss.settings.skin.value == Skins.Samsung)
                                  SliverToBoxAdapter(
                                    child: ConstrainedBox(
                                      constraints: BoxConstraints(
                                          minHeight: context.height -
                                              50 -
                                              context.mediaQueryPadding.top -
                                              context.mediaQueryViewPadding.top),
                                      child: CustomScrollView(
                                        physics: const NeverScrollableScrollPhysics(),
                                        shrinkWrap: true,
                                        slivers: devicesBodySlivers,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          ScrollbarWrapper(
                            controller: controller2,
                            child: CustomScrollView(
                              controller: controller2,
                              slivers: [
                                if (samsung) buildSamsungAppBar(context, "FindMy Friends"),
                                if (!samsung) ...friendsBodySlivers,
                                if (samsung)
                                  SliverToBoxAdapter(
                                    child: ConstrainedBox(
                                      constraints: BoxConstraints(
                                          minHeight: context.height -
                                              50 -
                                              context.mediaQueryPadding.top -
                                              context.mediaQueryViewPadding.top),
                                      child: CustomScrollView(
                                        physics: const NeverScrollableScrollPhysics(),
                                        shrinkWrap: true,
                                        slivers: friendsBodySlivers,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (samsung) buildDesktopTabBar()
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildDesktopTabBar() {
    return TabBar(
      controller: tabController,
      dividerColor: context.theme.dividerColor.withOpacity(0.2),
      tabs: [
        Container(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(iOS ? CupertinoIcons.device_desktop : Icons.devices),
              const Text("Devices"),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(iOS ? CupertinoIcons.person_2 : Icons.person),
              const Text("Friends"),
            ],
          ),
        ),
      ],
    );
  }

  Widget wrapDelete(Widget child, Function(BuildContext) onPressed) {
    return Slidable(
      endActionPane: ActionPane(
        motion: const StretchMotion(),
        extentRatio: 0.30,
        children: [
          SlidableAction(
            label: 'Remove',
            backgroundColor: Colors.red,
            icon: ss.settings.skin.value == Skins.iOS ? CupertinoIcons.trash : Icons.delete_outlined,
            onPressed: (_) async {
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (BuildContext context) {
                  return AlertDialog(
                    backgroundColor: context.theme.colorScheme.properSurface,
                    title: Text(
                      "Deleting...",
                      style: context.theme.textTheme.titleLarge,
                    ),
                    content: Container(
                      height: 70,
                      child: Center(child: buildProgressIndicator(context)),
                    ),
                  );
                }
              );
              await onPressed(context);
              Get.back();
            },
          ),
        ],
      ),
      child: child,
    );
  }

  Widget buildNormal(BuildContext context, List<SliverList> devicesBodySlivers, List<SliverList> friendsBodySlivers) {
    return Obx(
      () => Scaffold(
        backgroundColor: material ? tileColor : headerColor,
        body: Stack(
          children: [
            SlidingUpPanel(
              controller: panelController,
              color: Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(25.0),
                topRight: Radius.circular(25.0),
              ),
              minHeight: 50,
              maxHeight: MediaQuery.of(context).size.height * 0.75,
              disableDraggableOnScrolling: true,
              backdropEnabled: true,
              parallaxEnabled: true,
              header: ForceDraggableWidget(
                child: SizedBox(
                  width: MediaQuery.of(context).size.width,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 10.0, bottom: 40),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Container(
                        width: 50,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.outline,
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              panelBuilder: () => TabBarView(
                physics: const NeverScrollableScrollPhysics(),
                controller: tabController,
                children: <Widget>[
                  NotificationListener<ScrollEndNotification>(
                    onNotification: (_) {
                      if (ss.settings.skin.value != Skins.Samsung || kIsWeb || kIsDesktop) return false;
                      final scrollDistance = context.height / 3 - 57;

                      if (controller1.offset > 0 && controller1.offset < scrollDistance) {
                        final double snapOffset = controller1.offset / scrollDistance > 0.5 ? scrollDistance : 0;

                        Future.microtask(() => controller1.animateTo(snapOffset,
                            duration: const Duration(milliseconds: 200), curve: Curves.linear));
                      }
                      return false;
                    },
                    child: ScrollbarWrapper(
                      controller: controller1,
                      child: Obx(
                        () => CustomScrollView(
                          controller: controller1,
                          physics: (kIsDesktop || kIsWeb)
                              ? const NeverScrollableScrollPhysics()
                              : ThemeSwitcher.getScrollPhysics(),
                          slivers: <Widget>[
                            if (samsung) buildSamsungAppBar(context, "FindMy Devices"),
                            if (ss.settings.skin.value != Skins.Samsung) ...devicesBodySlivers,
                            if (ss.settings.skin.value == Skins.Samsung)
                              SliverToBoxAdapter(
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                      minHeight: context.height -
                                          50 -
                                          context.mediaQueryPadding.top -
                                          context.mediaQueryViewPadding.top),
                                  child: CustomScrollView(
                                    physics: const NeverScrollableScrollPhysics(),
                                    shrinkWrap: true,
                                    slivers: devicesBodySlivers,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  NotificationListener<ScrollEndNotification>(
                    onNotification: (_) {
                      if (ss.settings.skin.value != Skins.Samsung || kIsWeb || kIsDesktop) return false;
                      final scrollDistance = context.height / 3 - 57;

                      if (controller2.offset > 0 && controller2.offset < scrollDistance) {
                        final double snapOffset = controller2.offset / scrollDistance > 0.5 ? scrollDistance : 0;

                        Future.microtask(() => controller2.animateTo(snapOffset,
                            duration: const Duration(milliseconds: 200), curve: Curves.linear));
                      }
                      return false;
                    },
                    child: ScrollbarWrapper(
                      controller: controller2,
                      child: Obx(
                        () => CustomScrollView(
                          controller: controller2,
                          physics: (kIsDesktop || kIsWeb)
                              ? const NeverScrollableScrollPhysics()
                              : ThemeSwitcher.getScrollPhysics(),
                          slivers: <Widget>[
                            if (samsung) buildSamsungAppBar(context, "FindMy Friends"),
                            if (ss.settings.skin.value != Skins.Samsung) ...friendsBodySlivers,
                            if (ss.settings.skin.value == Skins.Samsung)
                              SliverToBoxAdapter(
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                      minHeight: context.height -
                                          50 -
                                          context.mediaQueryPadding.top -
                                          context.mediaQueryViewPadding.top),
                                  child: CustomScrollView(
                                    physics: const NeverScrollableScrollPhysics(),
                                    shrinkWrap: true,
                                    slivers: friendsBodySlivers,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              body: buildMap(),
            ),
            if (!samsung)
              Positioned(
                  top: 10 + (kIsDesktop ? appWindow.titleBarHeight : MediaQuery.of(context).padding.top),
                  left: 20,
                  child: Container(
                    width: 48,
                    height: 48,
                    child: buildBackButton(context, padding: const EdgeInsets.only(right: 2)),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(context).colorScheme.properSurface.withOpacity(0.9),
                    ),
                  )),
            if (!samsung && canRefresh)
              Positioned(
                top: 10 + (kIsDesktop ? appWindow.titleBarHeight : MediaQuery.of(context).padding.top),
                right: 20,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Theme.of(context).colorScheme.properSurface.withOpacity(0.9),
                  ),
                  child: Container(
                    width: 48,
                    child: refreshing || refreshing2
                        ? buildProgressIndicator(context)
                        : IconButton(
                            iconSize: 22,
                            icon: Icon(iOS ? CupertinoIcons.arrow_counterclockwise : Icons.refresh,
                                color: context.theme.colorScheme.onBackground, size: 22),
                            onPressed: () {
                              setState(() {
                                refreshing = true;
                                refreshing2 = true;
                              });
                              getLocations(refreshDevices: true);
                            },
                          ),
                  ),
                ),
              ),
            if (kIsDesktop)
              SizedBox(
                height: appWindow.titleBarHeight,
                child: AbsorbPointer(
                  child: Row(children: [
                    Expanded(child: Container()),
                    ClipRect(
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaY: 2, sigmaX: 2),
                        child: Container(
                            height: appWindow.titleBarHeight,
                            width: appWindow.titleBarButtonSize.width * 3,
                            color: context.theme.colorScheme.properSurface.withOpacity(0.5)),
                      ),
                    ),
                  ]),
                ),
              ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: index.value,
          backgroundColor: headerColor,
          destinations: [
            NavigationDestination(
              icon: Icon(iOS ? CupertinoIcons.device_desktop : Icons.devices),
              label: "DEVICES",
            ),
            NavigationDestination(
              icon: Icon(iOS ? CupertinoIcons.person_2 : Icons.person),
              label: "FRIENDS",
            ),
          ],
          onDestinationSelected: (page) {
            index.value = page;
            tabController.animateTo(page);
            if (index.value == page && panelController.isPanelOpen) {
              panelController.close();
            } else {
              panelController.open();
            }
          },
        ),
      ),
    );
  }

  Widget buildSamsungAppBar(BuildContext context, String title) {
    final actions = [
      if (canRefresh)
        Container(
          width: 48,
          height: 48,
          child: Container(
            width: 48,
            margin: const EdgeInsets.only(right: 8),
            child: refreshing || refreshing2
                ? buildProgressIndicator(context)
                : IconButton(
                    iconSize: 22,
                    icon: Icon(iOS ? CupertinoIcons.arrow_counterclockwise : Icons.refresh,
                        color: context.theme.colorScheme.onBackground, size: 22),
                    onPressed: () {
                      setState(() {
                        refreshing = true;
                        refreshing2 = true;
                      });
                      getLocations(refreshDevices: true);
                    },
                  ),
          ),
        ),
    ];

    return SliverAppBar(
      backgroundColor: headerColor,
      pinned: true,
      stretch: true,
      expandedHeight: context.height / 3,
      elevation: 0,
      automaticallyImplyLeading: false,
      flexibleSpace: LayoutBuilder(
        builder: (context, constraints) {
          var expandRatio = (constraints.maxHeight - 50) / (context.height / 3 - 50);

          if (expandRatio > 1.0) expandRatio = 1.0;
          if (expandRatio < 0.0) expandRatio = 0.0;
          final animation = AlwaysStoppedAnimation<double>(expandRatio);

          return Stack(
            fit: StackFit.expand,
            children: [
              FadeTransition(
                opacity: Tween(begin: 0.0, end: 1.0).animate(CurvedAnimation(
                  parent: animation,
                  curve: const Interval(0.3, 1.0, curve: Curves.easeIn),
                )),
                child: Center(
                    child: Text(title,
                        style: context.theme.textTheme.displaySmall!
                            .copyWith(color: context.theme.colorScheme.onBackground),
                        textAlign: TextAlign.center)),
              ),
              FadeTransition(
                opacity: Tween(begin: 1.0, end: 0.0).animate(CurvedAnimation(
                  parent: animation,
                  curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
                )),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Container(
                    padding: const EdgeInsets.only(left: 40),
                    height: 50,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        title,
                        style: context.theme.textTheme.titleLarge,
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 8.0),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Container(
                    height: 50,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: buildBackButton(context),
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomRight,
                child: Container(
                  height: 50,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: actions,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Build a Google Maps web URL for copying/sharing (works in any browser on any platform).
  String _googleMapsWebUrl(double lat, double lng) =>
      "https://www.google.com/maps/search/?api=1&query=$lat,$lng";

  /// Build a geo: intent URI for opening directly in the native map app on Android.
  /// When a label is available, uses the `q=LAT,LNG(Label)` format which shows a named pin.
  /// Without a label, just shows a pin at the coords.
  String _geoIntentUrl(double lat, double lng, {String? label}) {
    if (label != null && label.isNotEmpty) {
      return "geo:$lat,$lng?q=$lat,$lng(${Uri.encodeComponent(label)})";
    }
    return "geo:$lat,$lng?q=$lat,$lng";
  }

  /// Long-press action sheet for a location popup: open in Google Maps or copy the link.
  Future<void> _showLocationActions(double lat, double lng, {String? label}) async {
    final webUrl = _googleMapsWebUrl(lat, lng);
    final geoUrl = _geoIntentUrl(lat, lng, label: label);
    await showModalBottomSheet(
      context: context,
      backgroundColor: context.theme.colorScheme.properSurface,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.map_outlined),
              title: const Text("Open in Google Maps"),
              onTap: () async {
                Navigator.of(context).pop();
                await launchUrl(Uri.parse(geoUrl));
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text("Copy Google Maps link"),
              onTap: () async {
                Navigator.of(context).pop();
                await Clipboard.setData(ClipboardData(text: webUrl));
                showSnackbar("Copied", "Google Maps link copied to clipboard");
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Generic popup used for the dropped pin from a received maps link.
  Widget _mapPopup(BuildContext context, {required String title, required String subtitle, required double lat, required double lng}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5.0),
      child: GestureDetector(
        onLongPress: () => _showLocationActions(lat, lng, label: title),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: context.theme.colorScheme.properSurface.withOpacity(0.8),
          ),
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: context.theme.textTheme.labelLarge),
              if (!ss.settings.redactedMode.value)
                Text(subtitle, style: context.theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildMap() {
    var lastLocation = ss.settings.lastLocation.value?.split(",");
    var savedLocation = lastLocation != null ? LatLng(double.parse(lastLocation[0]), double.parse(lastLocation[1])) : const LatLng(0, 0);
    return FlutterMap(
      mapController: mapController,
      options: MapOptions(
        initialZoom: location == null ? 14.0 : 15.0,
        minZoom: 1.0,
        maxZoom: 18.0,
        initialCenter: location == null ? savedLocation : LatLng(location!.latitude, location!.longitude),
        onTap: (_, __) => popupController.hideAllPopups(),
        // Hide popup when the map is tapped.
        keepAlive: true,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
        onMapReady: () {
          if (!completer.isCompleted) {
            completer.complete();
          }
        },
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.bluebubbles.app',
        ),
        PopupMarkerLayer(
          options: PopupMarkerLayerOptions(
            onPopupEvent: (ev, m) async {
              // Same orphaned-marker hazard as the popup builder below: a marker can
              // outlive its friend, and firstWhere would throw an unhandled exception
              // out of this async callback. `friend:` is already nullable.
              final item = m.isEmpty ? null : friends
                      .firstWhereOrNull((e) => e.latitude == m[0].point.latitude && e.longitude == m[0].point.longitude)?.id;
              await api.selectBackgroundFriend(fmfd: pushService.state!.icloudServices!.fmfd!, friend: item);
            },
            popupController: popupController,
            markers: markers.values.toList(),
            popupDisplayOptions: PopupDisplayOptions(
              builder: (context, marker) {
                final ValueKey? key = marker.key as ValueKey?;
                if (key?.value == "current") return const SizedBox();
                if (key?.value == "dropped-pin") {
                  return _mapPopup(
                    context,
                    title: widget.initialLabel ?? "Shared Location",
                    subtitle: "${marker.point.latitude.toStringAsFixed(5)}, ${marker.point.longitude.toStringAsFixed(5)}",
                    lat: marker.point.latitude,
                    lng: marker.point.longitude,
                  );
                }
                if (key?.value.contains("device")) {
                  String prefix = key!.value.replaceFirst("device-", "");
                  // `markers` is only ever added to, never pruned, so a device that
                  // disappears from a later refresh leaves an orphaned marker behind.
                  // An unguarded firstWhere here threw "Bad state: No element" during
                  // build, which surfaced as a render error. Render nothing instead.
                  final item = devices.firstWhereOrNull((e) => e.id == prefix);
                  if (item == null) return const SizedBox();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 5.0),
                    child: GestureDetector(
                      onLongPress: (item.location?.latitude != null && item.location?.longitude != null)
                          ? () => _showLocationActions(item.location!.latitude!, item.location!.longitude!, label: item.name)
                          : null,
                      child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: context.theme.colorScheme.properSurface.withOpacity(0.8),
                      ),
                      padding: const EdgeInsets.fromLTRB(10, 10, 0, 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(ss.settings.redactedMode.value ? "Device" : (item.name ?? "Unknown Device"), style: context.theme.textTheme.labelLarge),
                              Text(ss.settings.redactedMode.value ? "Location" : (item.location?.latitude != null ? "${item.location?.latitude}, ${item.location?.longitude}" : ""),
                                  style: context.theme.textTheme.bodySmall),
                            ],
                          ),
                          if (item.location?.latitude != null && item.location?.longitude != null)
                          ButtonTheme(
                            minWidth: 1,
                            child: TextButton(
                              style: TextButton.styleFrom(
                                shape: const CircleBorder(),
                                backgroundColor: context.theme.colorScheme.primaryContainer,
                              ),
                              onPressed: () async {
                                await MapsLauncher.launchCoordinates(item.location!.latitude!, item.location!.longitude!);
                              },
                              child: const Icon(
                                  Icons.directions,
                                  size: 20
                              ),
                            ),
                          )
                        ],
                      )
                    ),
                  ),
                  );
                } else {
                  String prefix = key!.value.replaceFirst("friend-", "");
                  // Same orphaned-marker guard as the device branch above.
                  final item = friends.firstWhereOrNull((e) => e.handle?.uniqueAddressAndService == prefix);
                  if (item == null) return const SizedBox();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 5.0),
                    child: GestureDetector(
                      onLongPress: (item.latitude != null && item.longitude != null)
                          ? () => _showLocationActions(item.latitude!, item.longitude!, label: item.handle?.displayName ?? item.title)
                          : null,
                      child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: context.theme.colorScheme.properSurface.withOpacity(0.8),
                      ),
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.handle?.displayName ?? item.title ?? "Unknown Friend",
                              style: context.theme.textTheme.labelLarge),
                          Text(ss.settings.redactedMode.value ? "Location" : (item.longAddress ?? "No location found"), style: context.theme.textTheme.bodySmall),
                          if (item.lastUpdated != null && item.status != LocationStatus.live)
                            Text("Last updated ${buildDate(item.lastUpdated)}", style: context.theme.textTheme.bodySmall),
                          if (item.status != null)
                            Text("${item.status!.name.capitalize!} Location", style: context.theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                    ),
                  );
                }
              },
            ),
          ),
        ),
      ],
    );
  }
}

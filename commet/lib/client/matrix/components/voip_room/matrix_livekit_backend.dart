import 'dart:convert';

import 'package:commet/client/components/voip/voip_session.dart';
import 'package:commet/client/components/voip/webrtc_default_devices.dart';
import 'package:commet/client/matrix/components/voip_room/matrix_livekit_encryption_key_provider.dart';
import 'package:commet/client/matrix/components/voip_room/matrix_livekit_voip_session.dart';
import 'package:commet/client/matrix/components/voip_room/matrix_voip_room_component.dart';
import 'package:commet/client/matrix/matrix_room.dart';
import 'package:commet/debug/log.dart';
import 'package:commet/main.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart';

class MatrixLivekitBackend {
  MatrixRoom room;
  lk.Room? livekitRoom;
  MatrixLivekitBackend(this.room);

  Future<List<Uri>> getFociUrl() async {
    final selectedFocus = findSelectedFocus();

    var wellKnown = await room.matrixRoom.client.getWellknown();
    final livekitJwtServiceUrl = wellKnown
        .additionalProperties["org.matrix.msc4143.rtc_foci"] as List<dynamic>?;

    if (livekitJwtServiceUrl == null) {
      return [
        if (selectedFocus != null) selectedFocus,
      ];
    }

    Uri? fociUrl;
    for (var focus in livekitJwtServiceUrl) {
      Log.d("Focus: ${focus}");
      final data = focus as Map<String, dynamic>;
      if (data["type"] != "livekit") {
        continue;
      }

      final url = data["livekit_service_url"] as String;
      fociUrl = Uri.parse(url);

      return [
        if (selectedFocus != null) selectedFocus,
        if (selectedFocus != fociUrl) fociUrl,
      ];
    }

    return [
      if (selectedFocus != null) selectedFocus,
    ];
  }

  Uri? findSelectedFocus() {
    final states =
        room.matrixRoom.states[MatrixVoipRoomComponent.callMemberStateEvent];
    if (states == null) {
      return null;
    }

    return selectFocus(
      [
        for (final state in states.values)
          (
            originServerTs:
                (state as Event).originServerTs.millisecondsSinceEpoch,
            content: state.content as Map<String, dynamic>,
          ),
      ],
      room.identifier,
    );
  }

  /// Applies the `oldest_membership` focus selection algorithm: memberships
  /// are considered oldest first, and the focus we settle on is the first
  /// livekit focus advertised by an existing member that also points at this
  /// room's livekit alias.
  ///
  /// Every member runs this over the same state, so all clients converge on
  /// one focus. A disagreement here is not loud: the client that picked a
  /// different SFU simply never sees the other participants' media.
  static Uri? selectFocus(
      List<({int originServerTs, Map<String, dynamic> content})> memberships,
      String livekitAlias) {
    final ordered = [...memberships]
      ..sort((a, b) => a.originServerTs.compareTo(b.originServerTs));

    for (var membership in ordered) {
      final focusActive =
          membership.content.tryGet<Map<String, dynamic>>("focus_active");

      if (focusActive == null) {
        continue;
      }

      if (focusActive['type'] != "livekit") {
        Log.e("Unknown focus type: ${focusActive['type']}");
        continue;
      }

      if (focusActive['focus_selection'] != "oldest_membership") {
        Log.e(
            "Unknown focus selection algorithm: ${focusActive['focus_selection']}");
        continue;
      }

      final fociPreferred =
          membership.content.tryGet<List<dynamic>>("foci_preferred");
      if (fociPreferred == null) {
        continue;
      }

      for (var item in fociPreferred) {
        final map = item as Map<String, dynamic>;
        if (map['type'] != "livekit") continue;
        if (map['livekit_alias'] != livekitAlias) continue;
        return Uri.parse(map['livekit_service_url']);
      }
    }

    return null;
  }

  Future<VoipSession?> join() async {
    WebrtcDefaultDevices.selectOutputDevice();

    final fociUrl = await getFociUrl();

    if (fociUrl.isEmpty) {
      throw Exception("Failed to find a valid LiveKit service");
    }

    final selectedFocus = fociUrl.first;
    Log.d("Got Foci Url: ${fociUrl}");

    final token = await room.matrixRoom.client
        .requestOpenIdToken(room.matrixRoom.client.userID!, {});

    if (selectedFocus.scheme != "https") {
      throw Exception("Selected focus JWT does not use HTTPS");
    }

    Log.d("Received token from homeserver: ${token}");
    final uri = Uri.parse(selectedFocus.toString() + "/sfu/get");

    final body = {
      "device_id": room.matrixRoom.client.deviceID!,
      "room": room.matrixRoom.id,
      "openid_token": {
        "matrix_server_name": token.matrixServerName,
        "access_token": token.accessToken,
        "expires_in": token.expiresIn,
      }
    };

    var result = await http.post(uri, body: jsonEncode(body));
    if (result.statusCode != 200) {
      throw Exception("Failed to get sfu! HTTP Error ${result.statusCode}");
    }

    var data = jsonDecode(result.body) as Map<String, dynamic>;

    final sfuUrl = data["url"];
    Log.d("Got sfu: ${sfuUrl}");
    final jwt = data["jwt"];
    lk.E2EEOptions? e2eeOptions;

    MatrixLivekitEncryptionKeyProvider? provider;

    if (room.isE2EE) {
      provider =
          await MatrixLivekitEncryptionKeyProvider.create(room.matrixRoom);
      e2eeOptions = lk.E2EEOptions(keyProvider: provider);
    }

    final roomOptions = lk.RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        e2eeOptions: e2eeOptions,
        defaultAudioPublishOptions: lk.AudioPublishOptions(
          encoding: lk.AudioEncoding(
              maxBitrate:
                  (preferences.streamAudioBitrate.value * 1000).toInt()),
        ));

    final lkRoom = lk.Room(roomOptions: roomOptions);

    await lkRoom.prepareConnection(sfuUrl, jwt);
    final stateKey =
        "_${room.client.self!.identifier}_${room.matrixRoom.client.deviceID!}_m.call";

    await room.matrixRoom.client.setRoomStateWithKey(room.matrixRoom.id,
        MatrixVoipRoomComponent.callMemberStateEvent, stateKey, {
      "application": "m.call",
      "call_id": "",
      "device_id": room.matrixRoom.client.deviceID!,
      "expires": 14400000,
      "foci_preferred": fociUrl
          .map((e) => {
                "type": "livekit",
                "livekit_alias": room.identifier,
                "livekit_service_url": e.toString()
              })
          .toList(),
      "focus_active": {
        "focus_selection": "oldest_membership",
        "type": "livekit"
      },
      "scope": "m.room"
    });

    await lkRoom.connect(sfuUrl, jwt);

    var device = await WebrtcDefaultDevices.getDefaultMicrophoneId();

    print("Using default device: ${device}");

    lkRoom.localParticipant?.setMicrophoneEnabled(true,
        audioCaptureOptions: lk.AudioCaptureOptions(deviceId: device));

    livekitRoom = lkRoom;
    return MatrixLivekitVoipSession(room, lkRoom, keyProvider: provider);
  }
}

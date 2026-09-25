import 'package:commet/client/client.dart';
import 'package:commet/client/components/voip_room/voip_room_component.dart';
import 'package:commet/client/matrix/components/voip_room/matrix_voip_room_component.dart';
import 'package:commet/client/matrix/matrix_room.dart';
import 'package:commet/main.dart';
import 'package:commet/utils/rng.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart' as mx;

import '../extensions/common_flows.dart';

/// Covers the MatrixRTC setup that has to be correct before any media flows:
/// a voice room has to be created as an `msc3417.call` room, ordinary members
/// have to be able to write their own call membership, and the voip room
/// component has to be attached.
///
/// This deliberately stops short of joining. Joining needs a reachable SFU,
/// and a test that cannot tell "our membership is malformed" apart from "the
/// SFU was not running" is worse than no test.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Voice room gets a call component and call membership perms',
      (WidgetTester tester) async {
    await tester.clearUserData();

    var app = await tester.setupApp();
    await tester.pumpWidget(app);
    await tester.login(app);
    await tester.pumpAndSettle();

    var client = app.clientManager.clients.first;

    var created = await client.createRoom(CreateRoomArgs(
      name: "Voice ${RandomUtils.getRandomString(8)}",
      roomType: RoomType.voipRoom,
    ));

    var room = created as MatrixRoom;

    expect(room.matrixRoom.getState(mx.EventTypes.RoomCreate)?.content['type'],
        equals("org.matrix.msc3417.call"),
        reason: "a voice room must be created as an msc3417.call room");

    expect(MatrixVoipRoomComponent.isVoipRoom(room), isTrue,
        reason: "the created room must be recognised as a voice room");

    var component = room.getComponent<VoipRoomComponent>();
    expect(component, isNotNull,
        reason: "voice rooms must get a VoipRoomComponent attached");
    expect(component!.room.identifier, equals(room.identifier));

    // Joining writes the caller's own membership under a device scoped state
    // key, so the room has to let an ordinary member write that event.
    expect(component.canJoinCall, isTrue,
        reason:
            "members need power to write their own call membership to join");

    expect(component.getCurrentParticipants(), isEmpty,
        reason: "nobody has joined yet");

    await app.clientManager.close();
    await tester.clean();
  });
}

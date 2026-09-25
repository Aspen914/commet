import 'package:commet/client/matrix/components/voip_room/matrix_livekit_encryption_key_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// Memberships we must serve encryption keys to.
///
/// These cover the `msc3401.call.member` content shapes that Element and
/// Comet each emit. A regression here is silent: the remote client simply
/// never gets a key and renders nothing.
void main() {
  bool shouldSend(Map<String, dynamic> content) =>
      MatrixLivekitEncryptionKeyProvider.shouldSendKeysFor(content);

  group('shouldSendKeysFor', () {
    test('accepts a room scoped membership, which carries an empty call_id',
        () {
      expect(
          shouldSend({
            "application": "m.call",
            "call_id": "",
            "device_id": "DEVICE",
            "scope": "m.room",
          }),
          isTrue);
    });

    test('accepts a session scoped membership, which omits call_id', () {
      expect(
          shouldSend({
            "application": "m.call",
            "session_id": "SOME_SESSION",
            "device_id": "DEVICE",
            "scope": "m.room",
          }),
          isTrue);
    });

    test('rejects a membership for a different application', () {
      expect(
          shouldSend({
            "application": "m.rtc",
            "call_id": "",
          }),
          isFalse);
    });

    test('rejects a membership with no application', () {
      expect(shouldSend({"call_id": ""}), isFalse);
    });

    test('rejects a call_id that names a call other than this room', () {
      expect(
          shouldSend({
            "application": "m.call",
            "call_id": "SOME_OTHER_CALL",
          }),
          isFalse);
    });
  });
}

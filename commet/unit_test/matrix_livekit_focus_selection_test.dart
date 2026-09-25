import 'package:commet/client/matrix/components/voip_room/matrix_livekit_backend.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Membership = ({int originServerTs, Map<String, dynamic> content});

const roomAlias = "voice-room";
const ourFocus = "https://our-sfu.example.org";

Membership membership(int originServerTs,
        {String alias = roomAlias,
        String serviceUrl = ourFocus,
        String application = "livekit",
        String selection = "oldest_membership"}) =>
    (
      originServerTs: originServerTs,
      content: {
        "application": "m.call",
        "call_id": "",
        "scope": "m.room",
        "focus_active": {"type": application, "focus_selection": selection},
        "foci_preferred": [
          {
            "type": "livekit",
            "livekit_alias": alias,
            "livekit_service_url": serviceUrl
          }
        ],
      },
    );

/// `oldest_membership` focus selection.
///
/// Every member runs this over the same room state, so all clients have to
/// converge on the same SFU. A disagreement is not loud, it is just a client
/// that joined a different SFU and sees nobody.
void main() {
  Uri? select(List<Membership> memberships) =>
      MatrixLivekitBackend.selectFocus(memberships, roomAlias);

  test('returns null when nobody has joined', () {
    expect(select([]), isNull);
  });

  test('picks the focus of the oldest member', () {
    final focus = select([
      membership(2000, serviceUrl: "https://newer-sfu.example.org"),
      membership(1000, serviceUrl: ourFocus),
    ]);

    expect(focus.toString(), ourFocus);
  });

  test('picks the oldest member regardless of input order', () {
    final focus = select([
      membership(1000, serviceUrl: ourFocus),
      membership(2000, serviceUrl: "https://newer-sfu.example.org"),
    ]);

    expect(focus.toString(), ourFocus);
  });

  test('falls through to an older usable member when the newest is unusable',
      () {
    // A member that has not finished joining, or that advertises a focus we
    // do not support, must not strand the room on a focus nobody can reach.
    final focus = select([
      membership(1000, serviceUrl: ourFocus),
      membership(2000,
          serviceUrl: "https://x.example.org", application: "jingle"),
    ]);

    expect(focus.toString(), ourFocus);
  });

  test('ignores a membership advertising a focus for a different room', () {
    final focus = select([
      membership(1000,
          alias: "some-other-room",
          serviceUrl: "https://elsewhere.example.org"),
    ]);

    expect(focus, isNull);
  });

  test('ignores a membership with an unknown focus selection algorithm', () {
    final focus = select([membership(1000, selection: "random")]);

    expect(focus, isNull);
  });

  test('ignores a membership with no focus_active', () {
    expect(
        select([
          (originServerTs: 1000, content: {"application": "m.call"}),
        ]),
        isNull);
  });

  test('ignores a membership with no foci_preferred', () {
    expect(
        select([
          (
            originServerTs: 1000,
            content: {
              "application": "m.call",
              "focus_active": {
                "type": "livekit",
                "focus_selection": "oldest_membership"
              },
            }
          ),
        ]),
        isNull);
  });
}

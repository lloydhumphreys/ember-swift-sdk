// The ten translated payloads of ember-cloudflare's apps/worker/test/fixtures/slack_payloads.json:
// each one's name and the cards the server stores for it, as they come over the wire.
//
// A hand-copied snapshot, checked equal to the server at commit 7657ea4c (release 0.4.2). To refresh it after the
// server changes, copy each entry's `name` and `message.cards` from that file over the entries below, then run
//     EMBER_SERVER_CHECKOUT=/path/to/ember-cloudflare swift test --filter SlackFixtureDrift
// which fails on any difference and is skipped when the variable is not set.

import Foundation
import Testing

let slackCards: [(name: String, cards: String)] = [
    (
        name: "Prometheus Alertmanager, a firing alert from its default templates",
        cards: #"""
        [
          {
            "source": "attachment",
            "color": "danger",
            "parts": [
              {
                "kind": "title",
                "text": "[FIRING:2] InstanceDown (node-exporter production)",
                "href": "https://alertmanager.example.com/#/alerts?receiver=slack-alerts"
              }
            ]
          }
        ]
        """#
    ),
    (
        name: "Grafana Alerting, a firing alert from its default templates",
        cards: #"""
        [
          {
            "source": "attachment",
            "color": "#d63232",
            "parts": [
              {
                "kind": "title",
                "text": "[FIRING:1] HighCPU (web-1 production)",
                "href": "https://grafana.example.com/alerting/list"
              },
              {
                "kind": "text",
                "html": "<p>**Firing**<br><br>Value: A=97.2<br>Labels:<br> - alertname = HighCPU<br> - instance = web-1<br> - env = production<br>Annotations:<br> - summary = CPU above 90% for 5 minutes<br>Source: https://grafana.example.com/alerting/grafana/cpu-high/view?orgId=1<br>Silence: https://grafana.example.com/alerting/silence/new?alertmanager=grafana&amp;matcher=alertname%3DHighCPU<br>Dashboard: https://grafana.example.com/d/node-overview?orgId=1</p>"
              },
              {
                "kind": "footer",
                "text": "Grafana v12.2.0",
                "icon": "https://grafana.com/static/assets/img/fav32.png",
                "at": 1792584000
              }
            ]
          }
        ]
        """#
    ),
    (
        name: "GitLab, a pipeline that passed",
        cards: #"""
        [
          {
            "source": "attachment",
            "color": "good",
            "parts": [
              {
                "kind": "author",
                "name": "Ada Lovelace (ada)",
                "href": "https://gitlab.example.com/ada",
                "icon": "https://gitlab.example.com/uploads/-/system/user/avatar/1/avatar.png"
              },
              {
                "kind": "title",
                "text": "Pipeline #1042 has passed in 02:14",
                "href": "https://gitlab.example.com/acme/web/-/pipelines/1042"
              },
              {
                "kind": "fields",
                "fields": [
                  {
                    "title": "Branch",
                    "html": "<p><a href=\"https://gitlab.example.com/acme/web/-/commits/main\">main</a></p>",
                    "short": true
                  },
                  {
                    "title": "Commit",
                    "html": "<p><a href=\"https://gitlab.example.com/acme/web/-/commit/9f8e7d6c5b4a\">Fix the sign-in redirect</a></p>",
                    "short": true
                  }
                ]
              },
              {
                "kind": "footer",
                "text": "web",
                "icon": "https://gitlab.example.com/uploads/-/system/project/avatar/7/web.png",
                "at": 1792584000
              }
            ]
          }
        ]
        """#
    ),
    (
        name: "GitLab, a pipeline that failed",
        cards: #"""
        [
          {
            "source": "attachment",
            "color": "danger",
            "parts": [
              {
                "kind": "author",
                "name": "Ada Lovelace (ada)",
                "href": "https://gitlab.example.com/ada",
                "icon": "https://gitlab.example.com/uploads/-/system/user/avatar/1/avatar.png"
              },
              {
                "kind": "title",
                "text": "Pipeline #1043 has failed in 01:02",
                "href": "https://gitlab.example.com/acme/web/-/pipelines/1043/failures"
              },
              {
                "kind": "fields",
                "fields": [
                  {
                    "title": "Branch",
                    "html": "<p><a href=\"https://gitlab.example.com/acme/web/-/commits/main\">main</a></p>",
                    "short": true
                  },
                  {
                    "title": "Commit",
                    "html": "<p><a href=\"https://gitlab.example.com/acme/web/-/commit/0a1b2c3d4e5f\">Upgrade the test runner</a></p>",
                    "short": true
                  },
                  {
                    "title": "Failed stage",
                    "html": "<p><a href=\"https://gitlab.example.com/acme/web/-/pipelines/1043/failures\">test</a></p>",
                    "short": true
                  },
                  {
                    "title": "Failed jobs",
                    "html": "<p><a href=\"https://gitlab.example.com/acme/web/-/jobs/88231\">rspec 1/2</a>, <a href=\"https://gitlab.example.com/acme/web/-/jobs/88232\">rspec 2/2</a></p>",
                    "short": true
                  }
                ]
              },
              {
                "kind": "footer",
                "text": "web",
                "icon": "https://gitlab.example.com/uploads/-/system/project/avatar/7/web.png",
                "at": 1792584000
              }
            ]
          }
        ]
        """#
    ),
    (
        name: "Gitea, a push",
        cards: #"""
        [
          {
            "source": "attachment",
            "color": "#609926",
            "parts": [
              {
                "kind": "title",
                "text": "https://gitea.example.com/acme/web",
                "href": "https://gitea.example.com/acme/web"
              },
              {
                "kind": "text",
                "html": "<p><a href=\"https://gitea.example.com/acme/web/commit/9f8e7d6c5b4a\">9f8e7d6</a>: Fix the sign-in redirect - Ada Lovelace<br><a href=\"https://gitea.example.com/acme/web/commit/1a2b3c4d5e6f\">1a2b3c4</a>: Keep &lt;br&gt; in previews - Ada Lovelace</p>"
              }
            ]
          }
        ]
        """#
    ),
    (
        name: "Gitea, an issue opened, in a color written without its #",
        cards: #"""
        [
          {
            "source": "attachment",
            "color": "#eb6420",
            "parts": [
              {
                "kind": "title",
                "text": "#12 Sign-in fails on Safari",
                "href": "https://gitea.example.com/acme/web/issues/12"
              },
              {
                "kind": "text",
                "html": "<p>Open the sign-in page in Safari 18 &amp; sign in: the page reloads.</p>"
              }
            ]
          }
        ]
        """#
    ),
    (
        name: "Uptime Kuma, a monitor going down, as a rich message",
        cards: #"""
        [
          {
            "source": "attachment",
            "color": "#e01e5a",
            "parts": [
              {
                "kind": "header",
                "text": "Example API"
              },
              {
                "kind": "context",
                "items": [
                  {
                    "html": "<p><em>Production / APIs</em></p>"
                  }
                ]
              },
              {
                "kind": "section",
                "fields": [
                  {
                    "html": "<p><strong>Message</strong><br>[Example API] [🔴 Down] connect ECONNREFUSED 10.0.0.12:443</p>",
                    "short": true
                  },
                  {
                    "html": "<p><strong>Time (Europe/Berlin)</strong><br>2026-10-21 14:03:12</p>",
                    "short": true
                  }
                ]
              },
              {
                "kind": "buttons",
                "buttons": [
                  {
                    "text": "Visit Uptime Kuma",
                    "href": "https://status.example.com/dashboard/12"
                  },
                  {
                    "text": "Visit site",
                    "href": "https://api.example.com/"
                  }
                ]
              }
            ]
          }
        ]
        """#
    ),
    (
        name: "Block Kit Builder's approval template, whose buttons only an app could answer",
        cards: #"""
        [
          {
            "source": "blocks",
            "parts": [
              {
                "kind": "section",
                "html": "<p>You have a new request:<br><strong><a href=\"https://example.com/people/fred\">Fred Enriquez - New device request</a></strong></p>"
              },
              {
                "kind": "section",
                "fields": [
                  {
                    "html": "<p><strong>Type:</strong><br>Computer (laptop)</p>",
                    "short": true
                  },
                  {
                    "html": "<p><strong>When:</strong><br>Submitted Aug 10</p>",
                    "short": true
                  },
                  {
                    "html": "<p><strong>Last Update:</strong><br>Mar 10, 2015 (3 years, 5 months)</p>",
                    "short": true
                  },
                  {
                    "html": "<p><strong>Reason:</strong><br>All vowel keys aren't working.</p>",
                    "short": true
                  },
                  {
                    "html": "<p><strong>Specs:</strong><br>\"Cheetah Pro 15\" - Fast, really fast\"</p>",
                    "short": true
                  }
                ]
              }
            ]
          }
        ]
        """#
    ),
    (
        name: "A deploy summary in blocks, with a table",
        cards: #"""
        [
          {
            "source": "blocks",
            "parts": [
              {
                "kind": "header",
                "text": "Deployed web 2.4.0 🚀"
              },
              {
                "kind": "section",
                "button": {
                  "text": "Release notes",
                  "href": "https://example.com/releases/2.4.0",
                  "style": "primary"
                },
                "html": "<p><strong>3 services</strong> are live in <strong>production</strong>.</p>"
              },
              {
                "kind": "table",
                "rows": [
                  [
                    "<p>Service</p>",
                    "<p>Took</p>",
                    "<p>Errors</p>"
                  ],
                  [
                    "<p>api</p>",
                    "<p>1m 12s</p>",
                    "<p>0</p>"
                  ],
                  [
                    "<p>web</p>",
                    "<p>48s</p>",
                    "<p>0</p>"
                  ],
                  [
                    "<p><a href=\"https://example.com/workers\">workers</a></p>",
                    "<p>2m 3s</p>",
                    "<p>2</p>"
                  ]
                ],
                "columns": [
                  {
                    "align": "left",
                    "wrap": true
                  },
                  {
                    "align": "right",
                    "wrap": false
                  },
                  {
                    "align": "right",
                    "wrap": false
                  }
                ]
              },
              {
                "kind": "divider"
              },
              {
                "kind": "context",
                "items": [
                  {
                    "image": {
                      "url": "https://example.com/ada.png",
                      "alt": "Ada Lovelace"
                    }
                  },
                  {
                    "html": "<p>Started by <strong>Ada Lovelace</strong> at Oct 21, 2026 12:00 PM UTC</p>"
                  }
                ]
              }
            ]
          }
        ]
        """#
    ),
    (
        name: "Rooms to book, as a carousel of card blocks",
        cards: #"""
        [
          {
            "source": "blocks",
            "parts": [
              {
                "kind": "section",
                "html": "<p>Rooms free this afternoon</p>"
              },
              {
                "kind": "tiles",
                "tiles": [
                  {
                    "hero": {
                      "url": "https://example.com/rooms/lovelace.jpg",
                      "alt": "Lovelace, a room with a long table"
                    },
                    "title": "Lovelace",
                    "subtitle": "Second floor · 8 seats",
                    "buttons": [
                      {
                        "text": "Book",
                        "href": "https://example.com/rooms/lovelace/book",
                        "style": "primary"
                      },
                      {
                        "text": "Floor plan",
                        "href": "https://example.com/rooms/lovelace"
                      }
                    ],
                    "body": "<p>Free until <strong>4 PM</strong></p>"
                  },
                  {
                    "hero": {
                      "url": "https://example.com/rooms/hopper.jpg",
                      "alt": "Hopper, a room with a whiteboard"
                    },
                    "title": "Hopper",
                    "subtitle": "Third floor · 4 seats",
                    "buttons": [
                      {
                        "text": "Book",
                        "href": "https://example.com/rooms/hopper/book",
                        "style": "primary"
                      }
                    ],
                    "body": "<p>Free all afternoon</p>",
                    "subtext": "<p>Has a screen</p>"
                  }
                ]
              }
            ]
          }
        ]
        """#
    ),
]

private let serverCheckout = ProcessInfo.processInfo.environment["EMBER_SERVER_CHECKOUT"].flatMap { $0.isEmpty ? nil : $0 }

@Suite("Slack fixture drift", .enabled(if: serverCheckout != nil, "set EMBER_SERVER_CHECKOUT to a server checkout"))
struct SlackFixtureDrift {
    @Test func theSnapshotMatchesTheServersFixtures() throws {
        let root = try #require(serverCheckout)
        let url = URL(fileURLWithPath: root).appendingPathComponent("apps/worker/test/fixtures/slack_payloads.json")
        let server = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        #expect(server.count == slackCards.count, "the server has \(server.count) payloads, the snapshot \(slackCards.count)")
        for (entry, mine) in zip(server, slackCards) {
            #expect(entry["name"] as? String == mine.name, "\(mine.name)")
            let message = entry["message"] as? [String: Any]
            let mineCards = try JSONSerialization.jsonObject(with: Data(mine.cards.utf8))
            // NSObject equality compares the parsed trees, so key order and spacing don't count.
            #expect((message?["cards"] as? NSObject)?.isEqual(mineCards) == true, "\(mine.name)")
        }
    }
}

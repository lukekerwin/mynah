import Foundation
import MynahCore

/// Demo meetings for `MYNAH_UI_PREVIEW`, so the Meetings pages and the live
/// transcript pill can be opened and screenshotted without recording anything.
enum PreviewData {
    struct Seeded {
        var finished: String
        var live: String
    }

    static let liveScript: [(Track, String)] = [
        (.others, "Okay, I think everyone's here now. Let's pick up where we left off on the launch checklist."),
        (.you, "Sounds good. I finished the migration script yesterday, it's ready for review."),
        (.others, "Great. Priya, can you take a look at that this afternoon?"),
        (.others, "Sure, I'll have comments back before end of day."),
        (.you, "One thing to flag: the staging database still has the old schema, so we'll need to run it there first."),
        (.others, "Let's do that tomorrow morning then, before the demo."),
        (.you, "I'll put it on the calendar and send the runbook to the channel."),
        (.others, "Perfect. Next up, the pricing page copy."),
    ]

    @discardableResult
    static func seed(_ store: MeetingStore) -> Seeded {
        let now = Date()
        let cal = Calendar.current

        func meeting(_ title: String, daysAgo: Int, hour: Int, minutes: Double, app: String = "Microsoft Teams",
                     status: MeetingStatus = .done) -> Meeting {
            var start = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: now))!
            start = cal.date(bySettingHour: hour, minute: 0, second: 0, of: start)!
            var m = Meeting(title: title, appBundleID: "com.microsoft.teams2", appName: app, source: "auto", startedAt: start)
            m.endedAt = start.addingTimeInterval(minutes * 60)
            m.status = status
            m.hasSpeech = true
            m.youCursorS = minutes * 60
            m.othersCursorS = minutes * 60
            return m
        }

        let standup = meeting("Launch sync", daysAgo: 0, hour: 9, minutes: 27)
        let design = meeting("Pricing page review", daysAgo: 1, hour: 14, minutes: 48)
        let oneOnOne = meeting("1:1 with Priya", daysAgo: 1, hour: 16, minutes: 31, status: .queued)
        let vendor = meeting("Vendor call – Acme analytics", daysAgo: 4, hour: 11, minutes: 52, app: "Zoom")
        var live = Meeting(title: "Launch sync", appBundleID: "com.microsoft.teams2", appName: "Microsoft Teams",
                           source: "auto", startedAt: now.addingTimeInterval(-754))
        live.status = .recording

        do {
            for m in [standup, design, oneOnOne, vendor, live] { try store.createMeeting(m) }

            var t = 0.0
            for (track, text) in liveScript + liveScript {
                let seconds = Double(text.split(separator: " ").count) / 2.6
                try store.appendSegments(meetingID: standup.id, track: track, [(start: t, end: t + seconds, text: text)],
                                         cursor: t + seconds)
                t += seconds + 1.2
            }
            // Two voices on the other side: Priya (recognized) and someone not named yet.
            let priya = try store.person(named: "Priya")
            var labels: [Int64: String] = [:]
            for seg in try store.segments(meetingID: standup.id) where seg.track == .others {
                if let id = seg.id { labels[id] = seg.text.hasPrefix("Sure") ? "S2" : "S1" }
            }
            let voice = Voiceprint.encode((0..<256).map { Float(sin(Double($0))) })
            try store.saveSpeakers(meetingID: standup.id, [
                MeetingSpeaker(meetingID: standup.id, label: "S1", number: 1, speechS: 412, embedding: voice),
                MeetingSpeaker(meetingID: standup.id, label: "S2", number: 2, speechS: 186, embedding: voice,
                               personID: priya.id, matchScore: 0.86),
            ], segmentLabels: labels)
            try store.saveSummary(MeetingSummary(
                meetingID: standup.id, model: "gemma-4-e4b",
                tldr: "The team confirmed the migration script is ready for review and agreed to run it against staging before Thursday's demo. Pricing page copy is the next open item.",
                keyPoints: ["Migration script is complete and waiting on Priya's review.",
                            "Staging still runs the old schema and needs the migration first.",
                            "Demo is Thursday; the runbook goes to the channel today."],
                decisions: ["Run the migration on staging tomorrow morning, before the demo."],
                openQuestions: ["Who owns the pricing page copy after the review?"]),
                items: [ExtractedItem(text: "Send the migration runbook to the launch channel", owner: "me", timeS: 58),
                        ExtractedItem(text: "Review the migration script", owner: "Priya", due: "2026-10-16", timeS: 22),
                        ExtractedItem(text: "Schedule the staging migration for tomorrow morning", owner: "me", timeS: 70)])

            try store.saveSummary(MeetingSummary(
                meetingID: design.id, model: "gemma-4-e4b",
                tldr: "Walked through the three pricing tiers. The team prefers leading with the Team plan and cutting the comparison table down to the five rows people actually ask about.",
                keyPoints: ["Lead with the Team plan, not Free.", "Trim the comparison table to five rows.",
                            "Annual toggle stays, but defaults to monthly."],
                decisions: ["Ship the shorter comparison table in the next release."],
                openQuestions: []),
                items: [ExtractedItem(text: "Draft the five-row comparison table", owner: "me", due: "2026-10-20", timeS: 410)])
            _ = try store.addActionItem(text: "Book the launch retro", meetingID: nil)
        } catch {
            NSLog("Mynah: preview seed failed: \(error)")
        }
        return Seeded(finished: standup.id, live: live.id)
    }
}

//
//  ContentView.swift
//  BetterMail
//
//  Created by Isaac IBM on 5/11/2025.
//

import SwiftUI

import SwiftUI

struct ContentView: View {
    @State private var query = ""
    @State private var moveMailbox = "Projects/ACME"
    @State private var moveAccount = "Exchange"
    @State private var hits: [String] = []
    @State private var timeline: [[String:String]] = []
    @State private var status = ""
    @State private var isBuildingTimeline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("BetterMail").font(.title).bold()

            // Search
            HStack {
                TextField("Subject contains…", text: $query)
                Button("Search") {
                    Task {
                        do { hits = try MailControl.searchInboxSubject(contains: query) ; status = "✓ \(hits.count) hits" }
                        catch { status = "Search error: \(error)" }
                    }
                }
            }

            // Move / Flag actions on current Mail selection
            HStack {
                TextField("Mailbox path (e.g. Projects/ACME)", text: $moveMailbox).frame(width: 260)
                TextField("Account (e.g. Exchange)", text: $moveAccount).frame(width: 180)
                Button("Move Selection") {
                    Task {
                        do { try MailControl.moveSelection(to: moveMailbox, in: moveAccount); status = "✓ Moved" }
                        catch { status = "Move error: \(error)" }
                    }
                }
                Button("Flag Selection (Green)") {
                    Task {
                        do { try MailControl.flagSelection(colorIndex: 4); status = "✓ Flagged" }
                        catch { status = "Flag error: \(error)" }
                    }
                }
            }

            // Timeline
            HStack {
                Button("Build 7-day Timeline") {
                    isBuildingTimeline = true
                    Task {
                        do { timeline = try MailControl.fetchRecent(daysBack: 7, limit: 200); status = "✓ Timeline ready" }
                        catch { status = "Timeline error: \(error)" }
                        isBuildingTimeline = false
                    }
                }
                .disabled(isBuildingTimeline)
                if isBuildingTimeline {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text(status).foregroundColor(.secondary)
            }

            if !hits.isEmpty {
                Text("Search results (subjects)").font(.headline)
                List(hits, id: \.self) { Text($0) }.frame(minHeight: 120)
            }

            if !timeline.isEmpty {
                Text("Timeline (last 7 days)").font(.headline)
                List(timeline, id: \.self.description) { row in
                    HStack {
                        Text(row["date"] ?? "").frame(width: 180, alignment: .leading)
                        Text(row["sender"] ?? "").frame(width: 220, alignment: .leading)
                        Text(row["subject"] ?? "").lineLimit(1)
                    }.font(.callout)
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 520)
    }
}

import SwiftUI
import UIKit

struct RunMapDeviceSyncView: View {
    @ObservedObject private var sync = RunMapDeviceSync.shared
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var visibleCode: String?
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    Label(sync.status, systemImage: sync.isConnected ? "lock.shield" : "arrow.triangle.2.circlepath")
                    if let peerName = sync.peerName {
                        LabeledContent("Device", value: peerName)
                    }
                    if let date = sync.lastSyncedAt {
                        LabeledContent("Last synced") { Text(date, style: .relative) }
                    }
                    if sync.isPaired {
                        Toggle("Automatic Sync", isOn: Binding(
                            get: { sync.isEnabled },
                            set: { sync.setEnabled($0) }
                        ))
                        Button {
                            sync.syncNow()
                        } label: {
                            Label("Sync Now", systemImage: "arrow.clockwise")
                        }
                        .disabled(!sync.isEnabled)
                    }
                }

                if RunMapRuntime.isMac {
                    Section("Pair iPhone") {
                        Button {
                            visibleCode = sync.enableOnMac()
                        } label: {
                            Label(sync.isPaired ? "Show Pairing Code" : "Create Pairing Code", systemImage: "iphone")
                        }
                        if let visibleCode {
                            Text(visibleCode)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Button {
                                UIPasteboard.general.string = visibleCode
                            } label: {
                                Label("Copy Pairing Code", systemImage: "doc.on.doc")
                            }
                        }
                    }
                } else if !sync.isPaired {
                    Section("Pair with Mac") {
                        TextField("Pairing code from Mac", text: $code)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                        Button {
                            sync.pair(with: code)
                            code = ""
                        } label: {
                            Label("Pair with Mac", systemImage: "desktopcomputer")
                        }
                        .disabled((try? RunMapSyncCredentials.secret(from: code)) == nil)
                    }
                }

                if sync.isPaired {
                    Section {
                        Button(role: .destructive) { confirmForget = true } label: {
                            Label("Forget Pairing", systemImage: "link.badge.plus")
                        }
                    } footer: {
                        Text("Automatic sync runs while Explore! is open on both nearby devices.")
                    }
                }
            }
            .navigationTitle("Device Sync")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: RunMapRuntime.isMac ? 480 : nil, minHeight: RunMapRuntime.isMac ? 500 : nil)
        .confirmationDialog("Forget this pairing?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget Pairing", role: .destructive) {
                sync.forgetPairing()
                visibleCode = nil
            }
        } message: {
            Text("Workouts, goals, achievements, and saved plans remain on this device.")
        }
        .alert("Device Sync", isPresented: Binding(
            get: { sync.errorMessage != nil },
            set: { if !$0 { sync.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { sync.errorMessage = nil }
        } message: {
            Text(sync.errorMessage ?? "")
        }
    }
}

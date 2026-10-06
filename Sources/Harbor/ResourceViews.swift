import SwiftUI
import HarborCore

struct ResourceSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(title); Spacer(); Text("\(Int(value)) \(unit)").monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: $value, in: range, step: 1) { Text(title) }
                .labelsHidden()
                .accessibilityValue("\(Int(value)) \(unit)")
            HStack { Text("\(Int(range.lowerBound))"); Spacer(); Text("\(Int(range.upperBound)) \(unit)") }
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}

struct AccessInfoRow: View {
    let title: String
    let value: String
    let explanation: String
    @State private var showingInfo = false
    var body: some View {
        LabeledContent {
            Text(value).foregroundStyle(.secondary)
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Button { showingInfo.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("About \(title)").help("About \(title)")
                    .popover(isPresented: $showingInfo) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(title).font(.headline)
                            Text(explanation).fixedSize(horizontal: false, vertical: true)
                        }.padding(16).frame(width: 300)
                    }
            }
        }
    }
}

struct RuntimePreparationSection: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Section {
            LabeledContent("Workspace tools", value: model.preparing ? (model.checkingPreparedTools ? "Checking installed tools…" : model.cancelingPreparation ? "Cancelling…" : model.preparingBuild ? "Building…" : "Starting service…") : model.environmentReady ? "Ready" : "Preparation required")
            if !model.environmentReady { Text(model.runtimeStatus).font(.system(size: 12)).foregroundStyle(.secondary) }
            if model.runtimePath == nil {
                Text("Install Apple’s container runtime once to run local workspace tools.").font(.callout)
                Link("Get the Official Installer", destination: URL(string: "https://github.com/apple/container/releases/tag/1.5.0")!)
            }
            HStack {
                Button("Check Again") { Task { await model.refreshRuntime() } }.disabled(model.preparing)
                if model.runtimePath != nil {
                    Button(model.environmentReady ? "Rebuild Tools" : "Prepare Tools") { Task { await model.prepare() } }
                        .disabled(model.preparing || model.busy || model.storageBlocked || model.workspaces.contains { $0.runID != nil })
                }
                if model.preparing {
                    ProgressView().controlSize(.small)
                    Button(model.cancelingPreparation ? "Cancelling…" : "Cancel Build", role: .destructive) { model.cancelPreparation() }
                        .foregroundStyle(.red)
                        .disabled(!model.preparingBuild || model.cancelingPreparation)
                }
            }
            if model.preparing {
                Text(model.checkingPreparedTools ? "The build command has stopped. Checking whether previously installed tools are still usable…" : model.preparingBuild
                     ? "Cancel interrupts Harbor’s build command, like Control-C. The shared builder may remain running; cached downloads are kept."
                     : "Starting the local service cannot be cancelled here. Cancel Build becomes available when the tools build starts.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !model.setupLog.isEmpty {
                DisclosureGroup("Preparation log") {
                    ScrollView { Text(model.setupLog).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.frame(height: 140)
                }
            }
        } header: { Text("Local workspace tools") } footer: {
            Text("One-time preparation for all workspaces. Downloads tools and both assistants; requires internet and several GB of storage. No AI request is made.")
        }
    }
}

struct WorkspaceStatusView: View {
    let workspace: Workspace
    let project: URL
    @EnvironmentObject var model: AppModel
    private var summary: StorageSummary? { model.storageMeasurements[workspace.id] }
    private var scanError: String? { model.storageMeasurementErrors[workspace.id] }
    private var measuredAt: Date? { model.storageMeasuredAt[workspace.id] }
    @State private var scanning = false
    private func color(_ category: String) -> Color {
        switch category {
        case "Code": return .purple
        case "Images": return .blue
        case "Media": return .pink
        case "Documents": return .orange
        default: return .gray
        }
    }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    private func refresh() async {
        scanning = true; defer { scanning = false }
        await model.measureStorage(workspace.id)
    }
    var body: some View {
        Section("Resource status") {
            if let deadline = workspace.deadline, let start = workspace.startedAt, workspace.state.isActive {
                let total = max(1, deadline.timeIntervalSince(start))
                let elapsed = min(total, max(0, Date().timeIntervalSince(start)))
                ProgressView(value: elapsed, total: total) {
                    HStack { Text("Time used"); Spacer(); Text("\(Int(elapsed / 60)) of \(Int(total / 60)) min used").foregroundStyle(.secondary) }
                }
            } else { LabeledContent("Time limit", value: "\(workspace.minutes) min per run") }
            if let reading = model.readings[workspace.id] {
                let stale = workspace.state != .running || model.measurementErrors[workspace.id] != nil || Date().timeIntervalSince(reading.sampledAt) > 15
                if let fraction = reading.cpuFraction {
                    ProgressView(value: min(1, max(0, fraction))) {
                        LabeledContent("CPU used", value: "\(Int(fraction * 100))% of \(reading.allocatedCores) cores")
                    }.tint(stale ? .gray : .accentColor)
                } else { LabeledContent("CPU used", value: "Waiting for two samples · \(reading.allocatedCores) cores") }
                if let used = reading.sample.memoryUsageBytes, let limit = reading.sample.memoryLimitBytes, limit > 0 {
                    ProgressView(value: min(1, Double(used) / Double(limit))) {
                        LabeledContent("Memory used", value: "\(size(Int64(clamping: used))) of \(size(Int64(clamping: limit)))")
                    }.tint(stale ? .gray : .accentColor)
                } else { LabeledContent("Memory used", value: "Unavailable · \(workspace.memoryLimit) GB configured") }
                if let count = reading.sample.numProcesses { LabeledContent("Processes", value: "\(count)") }
                Text("\(stale ? "Last measurement" : "Measured") \(reading.sampledAt, style: .time)").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                LabeledContent("CPU limit", value: "\(workspace.cpuLimit) cores")
                LabeledContent("Memory limit", value: "\(workspace.memoryLimit) GB")
                Text(workspace.state == .running ? "Waiting for resource measurements…" : "Start a workspace to measure CPU and memory usage.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let message = model.measurementErrors[workspace.id] {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let usage = workspace.providerUsage {
                LabeledContent("Last reported input tokens", value: usage.inputTokens.formatted())
                LabeledContent("Last reported output tokens", value: usage.outputTokens.formatted())
                if let cost = usage.reportedCostUSD { LabeledContent("Provider-reported cost", value: cost.formatted(.currency(code: "USD"))) }
            }
            Text("CPU and memory are measured inside the workspace, not total macOS overhead. Provider usage is shown when reported; it may omit unfinished work and cache categories. Spending is not capped.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        Section("Working files") {
            if !workspace.showsFileBreakdown && (model.starterUnchanged[workspace.id] ?? true) {
                RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.2)).frame(height: 16)
                    .accessibilityLabel("No folder imported")
                Text("No folder imported · using Harbor’s starter files").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if let summary {
                Text("File types by size").font(.system(size: 12)).foregroundStyle(.secondary)
                LabeledContent("File size", value: "\(summary.partial ? "At least " : "")\(size(summary.total)) · \(summary.count) files")
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ForEach(StorageSummary.categories, id: \.self) { category in
                            let bytes = summary.bytes[category, default: 0]
                            if bytes > 0 {
                                Rectangle().fill(color(category))
                                    .frame(width: geometry.size.width * CGFloat(bytes) / CGFloat(max(1, summary.total)))
                                    .help("\(category): \(size(bytes))")
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 5))
                }.frame(height: 16).accessibilityLabel("File types by size; details below")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(StorageSummary.categories, id: \.self) { category in
                        HStack(spacing: 5) {
                            Circle().fill(color(category)).frame(width: 7, height: 7).accessibilityHidden(true)
                            Text("\(category) · \(size(summary.bytes[category, default: 0]))")
                        }.font(.system(size: 12))
                    }
                }
                if summary.partial { Text("Partial measurement: more than 100,000 entries. Totals are incomplete.").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            if let threshold = workspace.storageWarningMiB, let summary {
                let limit = Int64(threshold) * 1_048_576
                ProgressView(value: min(1, Double(summary.total) / Double(limit))) {
                    Text("\(size(summary.total)) · warning threshold \(size(limit))")
                }.tint(summary.total >= limit ? .orange : .accentColor)
                if summary.total >= limit {
                    Label("Storage warning reached. This is an alert threshold, not a disk quota.", systemImage: "exclamationmark.triangle").font(.system(size: 12))
                }
            }
            if let scanError { Label(scanError, systemImage: "exclamationmark.triangle").font(.system(size: 12)) }
            if workspace.showsFileBreakdown || !(model.starterUnchanged[workspace.id] ?? true) {
            HStack {
                if let measuredAt { Text("Measured \(measuredAt, style: .time)").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                if scanning { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await refresh() } }.disabled(scanning)
            }
            Text("File sizes in the working copy, grouped by extension. Excludes snapshots, runtime images and symbolic links; this is not total disk space used by Harbor.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.task(id: project) { await refresh() }
    }
}

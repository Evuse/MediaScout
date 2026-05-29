import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI
import WebKit

enum MediaKind: String, Codable, CaseIterable {
    case image
    case video
    case gif
    case unknown

    var label: String {
        switch self {
        case .image: return "Immagine"
        case .video: return "Video"
        case .gif: return "GIF"
        case .unknown: return "Media"
        }
    }

    var accent: Color {
        switch self {
        case .image: return Color(red: 0.06, green: 0.54, blue: 0.92)
        case .video: return Color(red: 0.92, green: 0.22, blue: 0.34)
        case .gif: return Color(red: 0.40, green: 0.28, blue: 0.86)
        case .unknown: return Color(red: 0.44, green: 0.50, blue: 0.56)
        }
    }
}

enum AnalysisEngine: String, CaseIterable, Identifiable {
    case chrome

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chrome: return "Chrome/Chromium background"
        }
    }
}

struct MediaCandidate: Identifiable, Decodable {
    let id = UUID()
    let url: String
    let type: MediaKind
    let source: String
    let referer: String?
    let width: Int?
    let height: Int?
    let poster: String?
    let contentType: String?
    let size: Int64?
    let audioURL: String?
    let familyKey: String?

    private enum CodingKeys: String, CodingKey {
        case url
        case type
        case source
        case referer
        case width
        case height
        case poster
        case contentType
        case size
        case audioURL
        case familyKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        let rawType = (try? container.decode(String.self, forKey: .type)) ?? "unknown"
        type = MediaKind(rawValue: rawType) ?? .unknown
        source = (try? container.decode(String.self, forKey: .source)) ?? "pagina"
        referer = try? container.decode(String.self, forKey: .referer)
        width = try? container.decode(Int.self, forKey: .width)
        height = try? container.decode(Int.self, forKey: .height)
        poster = try? container.decode(String.self, forKey: .poster)
        contentType = try? container.decode(String.self, forKey: .contentType)
        size = try? container.decode(Int64.self, forKey: .size)
        audioURL = try? container.decode(String.self, forKey: .audioURL)
        familyKey = try? container.decode(String.self, forKey: .familyKey)
    }
}

struct AnalysisReport: Decodable {
    let candidates: [MediaCandidate]
    let logs: [String]

    static let empty = AnalysisReport(candidates: [], logs: [])
}

struct SupportedSource: Identifiable {
    let id = UUID()
    let name: String
    let tint: Color
}

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case analyzer
    case gifStudio

    var id: String { rawValue }

    var label: String {
        switch self {
        case .analyzer: return "Analyzer"
        case .gifStudio: return "GIF Studio"
        }
    }
}

enum GIFPaletteSize: Int, CaseIterable, Identifiable {
    case colors256 = 256
    case colors128 = 128
    case colors64 = 64
    case colors32 = 32

    var id: Int { rawValue }
    var label: String { "\(rawValue)" }
}

enum GIFDitherStyle: String, CaseIterable, Identifiable {
    case none
    case bayer
    case floydSteinberg = "floyd_steinberg"
    case sierra2
    case sierra2_4a

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .bayer: return "Bayer"
        case .floydSteinberg: return "Floyd"
        case .sierra2: return "Sierra 2"
        case .sierra2_4a: return "Sierra 2-4A"
        }
    }
}

struct GIFConversionRequest {
    let sourceText: String
    let sourceCandidate: MediaCandidate?
    let pageURL: URL?
    let scalePercent: Int
    let fps: Int
    let lossyPercent: Int
    let paletteSize: GIFPaletteSize
    let ditherStyle: GIFDitherStyle
    let ditherIntensity: Int
    let trimStart: Double?
    let trimEnd: Double?
    let dropDuplicateFrames: Bool
    let frameDifferencing: Bool
}

final class AppState: ObservableObject {
    @Published var workspaceMode: WorkspaceMode = .analyzer
    @Published var urlText: String = ""
    @Published var candidates: [MediaCandidate] = []
    @Published var status: String = "Inserisci una URL: cerchero solo video e GIF."
    @Published var logs: [String] = []
    @Published var showVideos: Bool = true
    @Published var showGifs: Bool = true
    @Published var deepScroll: Bool = false
    @Published var includeNetworkResources: Bool = true
    @Published var autoAcceptCookies: Bool = true
    @Published var resultLimit: Int = 8
    @Published var isAnalyzing: Bool = false
    @Published var isDownloading: Bool = false
    @Published var gifSourceText: String = ""
    @Published var gifScalePercent: Int = 100
    @Published var gifFPS: Int = 12
    @Published var gifLossyPercent: Int = 20
    @Published var gifPaletteSize: GIFPaletteSize = .colors128
    @Published var gifDitherStyle: GIFDitherStyle = .sierra2_4a
    @Published var gifDitherIntensity: Int = 60
    @Published var gifTrimStart: String = "0"
    @Published var gifTrimEnd: String = ""
    @Published var gifDropDuplicateFrames: Bool = true
    @Published var gifFrameDifferencing: Bool = true
    @Published var isConvertingGIF: Bool = false
    @Published var gifStatus: String = "Scegli un video locale o una URL video e prepara la conversione."
    @Published var gifLogs: [String] = []
    @Published var gifOutputPath: String = ""

    private var gifSourceCandidate: MediaCandidate?
    private var gifSourcePageURL: URL?

    private let chromeAnalyzer = ChromeMediaAnalyzer()
    private let downloader = MediaDownloader()
    private let gifConverter = GIFConverter()

    var domainLabel: String {
        guard let url = URL(string: urlText), let host = url.host, !host.isEmpty else {
            return "Pronto"
        }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    var facebookMode: Bool {
        guard let host = URL(string: urlText)?.host?.lowercased() else { return false }
        return host == "facebook.com" || host.hasSuffix(".facebook.com") || host == "m.facebook.com" || host == "mbasic.facebook.com"
    }

    var totalSizeLabel: String {
        let total = filteredCandidates.compactMap { $0.size }.reduce(0, +)
        guard total > 0 else { return "Peso n.d." }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: total)
    }

    var quickSummary: String {
        if isAnalyzing {
            return facebookMode ? "Sto preparando Facebook, cookie e popup inclusi." : "Sto analizzando in background DOM, network e response body."
        }
        if filteredCandidates.isEmpty {
            return "Nessun risultato ancora."
        }
        return "\(filteredCandidates.count) media pronti per il download."
    }

    var supportedSources: [SupportedSource] {
        return [
            SupportedSource(name: "Facebook", tint: Color(red: 0.10, green: 0.45, blue: 0.94)),
            SupportedSource(name: "Instagram", tint: Color(red: 0.86, green: 0.22, blue: 0.48)),
            SupportedSource(name: "Pinterest", tint: Color(red: 0.82, green: 0.11, blue: 0.17)),
            SupportedSource(name: "Envato", tint: Color(red: 0.06, green: 0.71, blue: 0.39)),
            SupportedSource(name: "Dribbble", tint: Color(red: 0.92, green: 0.34, blue: 0.58)),
            SupportedSource(name: "Web generico", tint: Color(red: 0.46, green: 0.53, blue: 0.60))
        ]
    }

    var filteredCandidates: [MediaCandidate] {
        candidates.filter { candidate in
            switch candidate.type {
            case .video: return showVideos
            case .gif: return showGifs
            case .image, .unknown: return false
            }
        }
    }

    func analyze() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = URLNormalizer.url(from: trimmed) else {
            status = "URL non valida."
            return
        }

        urlText = normalized.absoluteString
        candidates = []
        logs = ["Analisi avviata: \(normalized.absoluteString)", "Motore: Chrome/Chromium background", "Tipi ammessi: video, GIF"]
        status = facebookMode ? "Avvio il browser, gestisco cookie Facebook e chiudo eventuali popup login..." : "Avvio il browser in background e catturo i primi media utili..."
        isAnalyzing = true

        let options = AnalyzerOptions(
            deepScroll: deepScroll,
            includeNetworkResources: includeNetworkResources,
            autoAcceptCookies: autoAcceptCookies,
            maxResults: resultLimit
        )
        let completion: (Result<AnalysisReport, Error>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isAnalyzing = false
                switch result {
                case .success(let report):
                    self.candidates = report.candidates
                    self.logs.append(contentsOf: report.logs)
                    if report.candidates.isEmpty {
                        self.status = "Nessun media scaricabile trovato. Apri i log per capire cosa e stato visto."
                    } else {
                        self.status = "Trovati \(report.candidates.count) elementi. Anteprime e download sono pronti."
                    }
                case .failure(let error):
                    self.logs.append("Errore: \(error.localizedDescription)")
                    self.status = "Analisi fallita: \(error.localizedDescription)"
                }
            }
        }

        chromeAnalyzer.analyze(url: normalized, options: options, completion: completion)
    }

    func download(_ candidate: MediaCandidate) {
        guard let url = URL(string: candidate.url) else {
            status = "URL media non valida."
            return
        }

        isDownloading = true
        status = "Scarico \(candidate.type.label.lowercased())..."

        downloader.download(
            url: url,
            audioURL: candidate.audioURL.flatMap(URL.init(string:)),
            pageURL: URL(string: urlText),
            referer: candidate.referer,
            suggestedName: FileNameBuilder.fileName(for: candidate)
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isDownloading = false
                switch result {
                case .success(let destination):
                    self.status = "Download completato: \(destination.path)"
                    self.logs.append("Scaricato: \(destination.path)")
                case .failure(let error):
                    self.status = "Download fallito: \(Self.compactErrorMessage(error.localizedDescription))"
                    self.logs.append("Download fallito per \(candidate.url): \(error.localizedDescription)")
                }
            }
        }
    }

    func copyURL(_ candidate: MediaCandidate) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(candidate.url, forType: .string)
        status = "URL copiata negli appunti."
    }

    func prepareGIFSource(from candidate: MediaCandidate) {
        gifSourceText = candidate.url
        gifSourceCandidate = candidate
        gifSourcePageURL = URL(string: urlText)
        gifStatus = "Sorgente GIF pronta da \(candidate.source)."
        workspaceMode = .gifStudio
    }

    func convertToGIF() {
        let source = gifSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            gifStatus = "Inserisci una URL video o il percorso di un file video."
            return
        }

        let request = GIFConversionRequest(
            sourceText: source,
            sourceCandidate: gifSourceCandidate,
            pageURL: gifSourcePageURL,
            scalePercent: gifScalePercent,
            fps: gifFPS,
            lossyPercent: gifLossyPercent,
            paletteSize: gifPaletteSize,
            ditherStyle: gifDitherStyle,
            ditherIntensity: gifDitherIntensity,
            trimStart: Double(gifTrimStart.replacingOccurrences(of: ",", with: ".")),
            trimEnd: gifTrimEnd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Double(gifTrimEnd.replacingOccurrences(of: ",", with: ".")),
            dropDuplicateFrames: gifDropDuplicateFrames,
            frameDifferencing: gifFrameDifferencing
        )

        isConvertingGIF = true
        gifOutputPath = ""
        gifLogs = ["Conversione GIF avviata da: \(source)"]
        gifStatus = "Sto preparando il video e converto in GIF..."

        gifConverter.convert(request: request, downloader: downloader) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isConvertingGIF = false
                switch result {
                case .success(let outputURL):
                    self.gifOutputPath = outputURL.path
                    self.gifStatus = "GIF pronta: \(outputURL.path)"
                    self.gifLogs.append("GIF creata: \(outputURL.path)")
                case .failure(let error):
                    self.gifStatus = "Conversione GIF fallita: \(Self.compactErrorMessage(error.localizedDescription))"
                    self.gifLogs.append("Errore GIF: \(error.localizedDescription)")
                }
            }
        }
    }

    private static func compactErrorMessage(_ raw: String) -> String {
        let cleaned = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let preferred = cleaned.first(where: { line in
            let lower = line.lowercased()
            return lower.contains("error") || lower.contains("invalid") || lower.contains("403") || lower.contains("failed") || lower.contains("impossible")
        })

        if let preferred = preferred {
            return preferred
        }

        let compact = cleaned.joined(separator: " ")
        if compact.count <= 160 {
            return compact
        }
        return String(compact.prefix(157)) + "..."
    }
}

struct ContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack {
            AppBackdrop()
            GeometryReader { proxy in
                VStack(spacing: 18) {
                    HeaderView(state: self.state)
                    WorkspaceModePicker(state: self.state)
                    SupportedSourcesStrip(state: self.state)
                    if self.state.workspaceMode == .analyzer {
                        MetricsStrip(state: self.state)
                        HStack(alignment: .top, spacing: 18) {
                            SidebarView(state: self.state)
                                .frame(width: min(330, max(280, proxy.size.width * 0.26)))
                            ResultsView(state: self.state)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        GIFStudioView(state: self.state)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(18)
        .frame(minWidth: 1120, minHeight: 760)
    }
}

struct WorkspaceModePicker: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack {
            Picker("", selection: $state.workspaceMode) {
                ForEach(WorkspaceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .frame(width: 260)
            Spacer()
        }
    }
}

struct AppBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.96, green: 0.98, blue: 1.0),
                    Color(red: 0.96, green: 0.99, blue: 0.97),
                    Color(red: 1.0, green: 0.97, blue: 0.94)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color(red: 0.20, green: 0.58, blue: 0.98).opacity(0.14))
                .frame(width: 360, height: 360)
                .offset(x: -380, y: -260)
            Circle()
                .fill(Color(red: 0.05, green: 0.78, blue: 0.55).opacity(0.10))
                .frame(width: 300, height: 300)
                .offset(x: 420, y: -220)
        }
        .edgesIgnoringSafeArea(.all)
    }
}

struct HeaderView: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Color(red: 0.10, green: 0.55, blue: 0.98)
                        .frame(width: 12, height: 12)
                        .cornerRadius(6)
                    Text("MediaScout")
                        .font(.system(size: 32, weight: .bold))
                }
                Text("Downloader visuale per video e GIF con analisi browser-side")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color.black.opacity(0.62))
                Text(state.facebookMode ? "Ottimizzato per sbloccare Facebook prima dell'analisi" : "Analisi rapida, ranking pesato e download diretto")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.black.opacity(0.45))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Text(state.facebookMode ? "Facebook Assist" : "Rapid Capture")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background((state.facebookMode ? Color.blue : Color.green).opacity(0.12))
                    .foregroundColor(state.facebookMode ? .blue : .green)
                    .cornerRadius(8)
                Text(state.domainLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color.black.opacity(0.55))
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 24)
        .background(Color.white.opacity(0.86))
        .cornerRadius(18)
        .shadow(color: Color.black.opacity(0.05), radius: 20, x: 0, y: 10)
    }
}

struct SupportedSourcesStrip: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(state.supportedSources) { source in
                    HStack(spacing: 8) {
                        source.tint
                            .frame(width: 9, height: 9)
                            .cornerRadius(5)
                        Text(source.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color.black.opacity(0.74))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(source.tint.opacity(self.badgeOpacity(for: source.name)))
                    .cornerRadius(999)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func badgeOpacity(for name: String) -> Double {
        let domain = state.domainLabel.lowercased()
        if name == "Facebook" && state.facebookMode { return 0.20 }
        if domain.contains("envato") && name == "Envato" { return 0.20 }
        if domain.contains("instagram") && name == "Instagram" { return 0.20 }
        if domain.contains("pinterest") && name == "Pinterest" { return 0.20 }
        if domain.contains("dribbble") && name == "Dribbble" { return 0.20 }
        return 0.08
    }
}

struct MetricsStrip: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            MetricTile(title: "Stato", value: state.isAnalyzing ? "Analisi" : "Pronto", tone: Color(red: 0.10, green: 0.55, blue: 0.98))
            MetricTile(title: "Risultati", value: "\(state.filteredCandidates.count)", tone: Color(red: 0.00, green: 0.72, blue: 0.52))
            MetricTile(title: "Peso totale", value: state.totalSizeLabel, tone: Color(red: 0.98, green: 0.54, blue: 0.18))
            MetricTile(title: "Modalita", value: state.facebookMode ? "Facebook" : "Standard", tone: Color(red: 0.90, green: 0.21, blue: 0.40))
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let tone: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color.black.opacity(0.45))
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Color.black.opacity(0.82))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.88))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(tone.opacity(0.22), lineWidth: 1)
        )
        .cornerRadius(16)
    }
}

struct SidebarView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PanelCard(title: "Nuova analisi", tint: Color(red: 0.10, green: 0.55, blue: 0.98)) {
                    TextField("https://example.com/post/...", text: $state.urlText, onCommit: {
                        self.state.analyze()
                    })
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Button(action: {
                        self.state.analyze()
                    }) {
                        HStack {
                            Spacer()
                            Text(state.isAnalyzing ? "Analisi in corso..." : "Analizza pagina")
                            Spacer()
                        }
                    }
                    .disabled(state.isAnalyzing || state.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text(state.quickSummary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.black.opacity(0.54))
                }

                PanelCard(title: "Settaggi", tint: Color(red: 0.98, green: 0.54, blue: 0.18)) {
                    Text("Chrome/Chromium gira in background con budget rapido sotto i 10 secondi.")
                        .font(.system(size: 12))
                        .foregroundColor(Color.black.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Scorrimento automatico", isOn: $state.deepScroll)
                    Toggle("Risorse network", isOn: $state.includeNetworkResources)
                    Toggle("Prova accettazione cookie", isOn: $state.autoAcceptCookies)
                    Stepper(value: $state.resultLimit, in: 3...30) {
                        Text("Risultati max: \(state.resultLimit)")
                    }
                    if state.facebookMode {
                        Text("Per Facebook il flusso prova prima ad accettare tutti i cookie e poi a chiudere l'eventuale popup login.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.blue.opacity(0.88))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                PanelCard(title: "Sorgenti", tint: Color(red: 0.53, green: 0.40, blue: 0.96)) {
                    Text("Queste sono le sorgenti che stiamo rendendo sempre piu affidabili.")
                        .font(.system(size: 12))
                        .foregroundColor(Color.black.opacity(0.58))
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(state.supportedSources) { source in
                            HStack(spacing: 10) {
                                source.tint
                                    .frame(width: 10, height: 10)
                                    .cornerRadius(5)
                                Text(source.name)
                                    .font(.system(size: 13, weight: .semibold))
                            }
                        }
                    }
                }

                PanelCard(title: "Formati", tint: Color(red: 0.00, green: 0.72, blue: 0.52)) {
                    Toggle("Video", isOn: $state.showVideos)
                    Toggle("GIF", isOn: $state.showGifs)
                }

                PanelCard(title: "Stato live", tint: Color(red: 0.90, green: 0.21, blue: 0.40)) {
                    Text(state.status)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color.black.opacity(0.62))
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 8)
        }
    }
}

struct PanelCard<Content: View>: View {
    let title: String
    let tint: Color
    let content: Content

    init(title: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                tint
                    .frame(width: 10, height: 10)
                    .cornerRadius(5)
                Text(title)
                    .font(.system(size: 16, weight: .bold))
            }
            content
        }
        .padding(16)
        .background(Color.white.opacity(0.9))
        .cornerRadius(18)
        .shadow(color: Color.black.opacity(0.04), radius: 16, x: 0, y: 8)
    }
}

struct ResultsView: View {
    @ObservedObject var state: AppState
    @State private var showLogs = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(state.filteredCandidates.count) risultati")
                        .font(.title)
                        .fontWeight(.semibold)
                    Text("Mostro solo video e GIF, ordinati dal file piu pesante al piu leggero.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(showLogs ? "Nascondi log" : "Mostra log") {
                    self.showLogs.toggle()
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            if showLogs {
                LogView(logs: state.logs)
                    .frame(height: 170)
            }

            if state.filteredCandidates.isEmpty {
                EmptyStateView(isAnalyzing: state.isAnalyzing)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(state.filteredCandidates) { candidate in
                            CandidateCard(candidate: candidate, isBusy: self.state.isDownloading, download: {
                                self.state.download(candidate)
                            }, copyURL: {
                                self.state.copyURL(candidate)
                            }, convertToGIF: {
                                self.state.prepareGIFSource(from: candidate)
                            })
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(Color.white.opacity(0.88))
        .cornerRadius(22)
        .shadow(color: Color.black.opacity(0.06), radius: 18, x: 0, y: 10)
    }
}

struct GIFStudioView: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PanelCard(title: "Sorgente video", tint: Color(red: 0.92, green: 0.34, blue: 0.58)) {
                        TextField("URL video o percorso file locale", text: $state.gifSourceText)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        Text("Puoi incollare un link diretto oppure usare il pulsante In GIF da un risultato analizzato.")
                            .font(.system(size: 12))
                            .foregroundColor(Color.black.opacity(0.58))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    PanelCard(title: "Qualita e peso", tint: Color(red: 0.98, green: 0.54, blue: 0.18)) {
                        Stepper(value: $state.gifScalePercent, in: 20...100, step: 5) {
                            Text("Risoluzione output: \(state.gifScalePercent)%")
                        }
                        Stepper(value: $state.gifFPS, in: 4...30) {
                            Text("Frame rate: \(state.gifFPS) fps")
                        }
                        Stepper(value: $state.gifLossyPercent, in: 0...100, step: 5) {
                            Text("Compressione lossy: \(state.gifLossyPercent)%")
                        }
                        Picker("Tavolozza colori", selection: $state.gifPaletteSize) {
                            ForEach(GIFPaletteSize.allCases) { size in
                                Text(size.label).tag(size)
                            }
                        }
                    }

                    PanelCard(title: "Dithering", tint: Color(red: 0.53, green: 0.40, blue: 0.96)) {
                        Picker("Tipo", selection: $state.gifDitherStyle) {
                            ForEach(GIFDitherStyle.allCases) { style in
                                Text(style.label).tag(style)
                            }
                        }
                        Stepper(value: $state.gifDitherIntensity, in: 0...100, step: 5) {
                            Text("Intensita: \(state.gifDitherIntensity)%")
                        }
                        Toggle("Ottimizzazione trasparenza / frame differencing", isOn: $state.gifFrameDifferencing)
                        Toggle("Rimozione fotogrammi duplicati", isOn: $state.gifDropDuplicateFrames)
                    }

                    PanelCard(title: "Trim temporale", tint: Color(red: 0.00, green: 0.72, blue: 0.52)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Inizio (sec)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextField("0", text: $state.gifTrimStart)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Fine (sec)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextField("lascia vuoto = fine video", text: $state.gifTrimEnd)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                            }
                        }
                    }

                    Button(action: {
                        self.state.convertToGIF()
                    }) {
                        HStack {
                            Spacer()
                            Text(state.isConvertingGIF ? "Conversione in corso..." : "Converti in GIF")
                            Spacer()
                        }
                    }
                    .disabled(state.isConvertingGIF || state.gifSourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.bottom, 8)
            }
            .frame(width: 360)

            VStack(spacing: 14) {
                PanelCard(title: "Anteprima output", tint: Color(red: 0.10, green: 0.55, blue: 0.98)) {
                    if !state.gifOutputPath.isEmpty {
                        GIFOutputPreview(path: state.gifOutputPath)
                            .frame(height: 300)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Text(state.gifOutputPath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    } else {
                        VStack(spacing: 10) {
                            Text("GIF Studio")
                                .font(Font.title.weight(.semibold))
                            Text("Riduci peso con scala, FPS, palette, dithering e trim, senza uscire dall app.")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 300)
                    }
                }

                PanelCard(title: "Stato conversione", tint: Color(red: 0.90, green: 0.21, blue: 0.40)) {
                    Text(state.gifStatus)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color.black.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }

                PanelCard(title: "Log GIF", tint: Color(red: 0.46, green: 0.53, blue: 0.60)) {
                    LogView(logs: state.gifLogs)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.white.opacity(0.88))
        .cornerRadius(22)
        .shadow(color: Color.black.opacity(0.06), radius: 18, x: 0, y: 10)
        .padding(.top, 4)
    }
}

struct GIFOutputPreview: View {
    let path: String

    @ViewBuilder
    var body: some View {
        if let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            VStack(spacing: 8) {
                Text("GIF creata")
                    .font(.headline)
                Text("Anteprima locale non disponibile")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct EmptyStateView: View {
    let isAnalyzing: Bool

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text(isAnalyzing ? "Sto ispezionando la pagina..." : "Nessun video o GIF visibile")
                .font(.headline)
                .fontWeight(.semibold)
            Text(isAnalyzing ? "Carico in background, accetto eventuali cookie e leggo DOM e network." : "Inserisci una URL o apri i log dopo un'analisi fallita.")
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LogView: View {
    let logs: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color.black.opacity(0.62))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
        .background(Color(red: 0.96, green: 0.98, blue: 1.0))
    }
}

struct CandidateCard: View {
    let candidate: MediaCandidate
    let isBusy: Bool
    let download: () -> Void
    let copyURL: () -> Void
    let convertToGIF: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                MediaPreview(candidate: candidate)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                candidate.type.accent.opacity(0.18),
                                Color.white
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(candidate.type.label)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(candidate.type.accent)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                    .padding(8)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(providerLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(candidate.type.accent)
                Text(candidate.source)
                    .font(.headline)
                    .lineLimit(1)
                Text(metaLine)
                .font(.caption)
                .foregroundColor(.secondary)
                Text(candidate.url)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Button("Copia URL", action: copyURL)
                if candidate.type == .video {
                    Button("In GIF", action: convertToGIF)
                }
                Spacer()
                Button("Scarica", action: download)
                    .disabled(isBusy)
            }
        }
        .padding(12)
        .background(Color.white)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(candidate.type.accent.opacity(0.18), lineWidth: 1)
        )
        .cornerRadius(16)
    }

    private var dimensionText: String? {
        guard let width = candidate.width, let height = candidate.height, width > 0, height > 0 else {
            return nil
        }
        return "\(width)x\(height)"
    }

    private var sizeText: String? {
        guard let size = candidate.size, size > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    private var metaLine: String {
        var parts: [String] = []
        if let dimensions = dimensionText { parts.append(dimensions) }
        if let size = sizeText { parts.append(size) }
        if let type = candidate.contentType, !type.isEmpty { parts.append(type) }
        if candidate.type == .video && candidate.audioURL != nil { parts.append("audio unito") }
        return parts.isEmpty ? "Dettagli non disponibili" : parts.joined(separator: "  ")
    }

    private var providerLabel: String {
        guard let host = URL(string: candidate.url)?.host?.lowercased() else {
            return "Sorgente sconosciuta"
        }
        if host.contains("facebook.com") || host.contains("fbcdn.net") {
            return "Facebook"
        }
        if host.contains("instagram.com") || host.contains("cdninstagram.com") {
            return "Instagram"
        }
        if host.contains("pinimg.com") || host.contains("pinterest.") {
            return "Pinterest"
        }
        if host.contains("envato") {
            return "Envato"
        }
        if host.contains("dribbble") {
            return "Dribbble"
        }
        return host
    }
}

struct MediaPreview: View {
    let candidate: MediaCandidate

    var body: some View {
        content
    }

    private var content: AnyView {
        if candidate.type == .video {
            return AnyView(VideoThumbnailView(candidate: candidate))
        } else if let previewURL = previewURL {
            return AnyView(RemoteImageView(url: previewURL))
        } else {
            return AnyView(VStack(spacing: 8) {
                Text(candidate.type == .video ? "VIDEO" : candidate.type.label.uppercased())
                    .font(.headline)
                    .foregroundColor(candidate.type.accent)
                Text("anteprima non disponibile")
                    .font(.caption)
                    .foregroundColor(.secondary)
            })
        }
    }

    private var previewURL: URL? {
        if let poster = candidate.poster, let url = URL(string: poster) {
            return url
        }
        if candidate.type == .gif {
            return URL(string: candidate.url)
        }
        return nil
    }
}

final class VideoThumbnailLoader: ObservableObject {
    @Published var image: NSImage?
    private var currentURL: URL?
    private var currentAsset: AVURLAsset?
    private var currentGenerator: AVAssetImageGenerator?

    func load(candidate: MediaCandidate) {
        guard let url = URL(string: candidate.url), currentURL != url else { return }
        currentURL = url
        image = nil

        let headers = [
            "User-Agent": UserAgents.safari,
            "Referer": candidate.referer ?? candidate.url
        ]

        DispatchQueue.global(qos: .userInitiated).async {
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 900, height: 560)
            let times = [NSValue(time: CMTime(seconds: 0.2, preferredTimescale: 600))]
            self.currentAsset = asset
            self.currentGenerator = generator

            generator.generateCGImagesAsynchronously(forTimes: times) { [weak self] _, cgImage, _, result, _ in
                guard let self = self else { return }
                guard self.currentURL == url else { return }
                guard result == .succeeded, let cgImage = cgImage else { return }
                let image = NSImage(cgImage: cgImage, size: .zero)
                DispatchQueue.main.async {
                    self.image = image
                    self.currentGenerator = nil
                    self.currentAsset = nil
                }
            }
        }
    }
}

struct VideoThumbnailView: View {
    let candidate: MediaCandidate
    @ObservedObject private var loader: VideoThumbnailLoader

    init(candidate: MediaCandidate) {
        self.candidate = candidate
        self._loader = ObservedObject(wrappedValue: VideoThumbnailLoader())
    }

    var body: some View {
        ZStack {
            previewContent

            VStack {
                Spacer()
                HStack {
                    Text("▶")
                    Text("preview")
                        .font(Font.caption.weight(.semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.28)))
                .clipShape(Capsule())
                .padding(12)
            }
        }
        .clipped()
        .onAppear {
            self.loader.load(candidate: self.candidate)
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if let image = loader.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let posterURL = candidate.poster.flatMap(URL.init(string:)) {
            RemoteImageView(url: posterURL)
        } else {
            LinearGradient(
                colors: [candidate.type.accent.opacity(0.95), Color.black.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 8) {
                Text("▶")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Text("estraggo thumbnail video")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.86))
            }
        }
    }
}

final class RemoteImageLoader: ObservableObject {
    @Published var image: NSImage?
    private var task: URLSessionDataTask?

    func load(url: URL) {
        task?.cancel()
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        task = URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                self.image = image
            }
        }
        task?.resume()
    }
}

struct RemoteImageView: View {
    let url: URL
    @ObservedObject private var loader = RemoteImageLoader()

    var body: some View {
        content
        .clipped()
        .onAppear {
            self.loader.load(url: self.url)
        }
    }

    private var content: AnyView {
        if loader.image != nil {
            return AnyView(Image(nsImage: loader.image!)
                .resizable()
                .aspectRatio(contentMode: .fill))
        }
        return AnyView(VStack(spacing: 8) {
            Text("...")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("carico anteprima")
                .font(.caption)
                .foregroundColor(.secondary)
        })
    }
}

struct AnalyzerOptions {
    let deepScroll: Bool
    let includeNetworkResources: Bool
    let autoAcceptCookies: Bool
    let maxResults: Int
}

final class PageMediaAnalyzer: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var completion: ((Result<AnalysisReport, Error>) -> Void)?
    private var options = AnalyzerOptions(deepScroll: false, includeNetworkResources: true, autoAcceptCookies: true, maxResults: 8)
    private var didComplete = false

    func analyze(url: URL, options: AnalyzerOptions, completion: @escaping (Result<AnalysisReport, Error>) -> Void) {
        didComplete = false
        self.options = options
        self.completion = completion

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptEnabled = true
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1440, height: 1100), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView

        var request = URLRequest(url: url)
        request.setValue(UserAgents.safari, forHTTPHeaderField: "User-Agent")
        webView.load(request)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if options.deepScroll {
            performAutoScroll(webView: webView, step: 0)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.extractCandidates()
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    private func performAutoScroll(webView: WKWebView, step: Int) {
        let script = "window.scrollTo(0, Math.floor((Math.max(document.body.scrollHeight, document.documentElement.scrollHeight) || 0) * \(step + 1) / 4));"
        webView.evaluateJavaScript(script) { [weak self] _, _ in
            guard let self = self else { return }
            if step >= 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.extractCandidates()
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    self.performAutoScroll(webView: webView, step: step + 1)
                }
            }
        }
    }

    private func extractCandidates() {
        guard let webView = webView else { return }
        let script = "window.__MEDIA_SCOUT_INCLUDE_NETWORK__ = \(options.includeNetworkResources ? "true" : "false");\n" + Self.extractionScript

        webView.evaluateJavaScript(script) { [weak self] value, error in
            if let error = error {
                let report = AnalysisReport(candidates: [], logs: ["WebKit JavaScript exception: \(error.localizedDescription)"])
                self?.finish(.success(report))
                return
            }

            guard let json = value as? String, let data = json.data(using: .utf8) else {
                self?.finish(.success(AnalysisReport(candidates: [], logs: ["WebKit non ha restituito JSON."])))
                return
            }

            do {
                let report = try JSONDecoder().decode(AnalysisReport.self, from: data)
                self?.finish(.success(report))
            } catch {
                self?.finish(.success(AnalysisReport(candidates: [], logs: ["Decodifica risultato WebKit fallita: \(error.localizedDescription)", "Payload: \(json.prefix(500))"])))
            }
        }
    }

    private func finish(_ result: Result<AnalysisReport, Error>) {
        guard !didComplete else { return }
        didComplete = true
        completion?(result)
        completion = nil
        webView?.navigationDelegate = nil
        webView = nil
    }

    static let extractionScript = """
    (function() {
      const logs = [];
      const found = [];
      const seen = new Set();
      const pageURL = (window.location && window.location.href) || '';
      const includeNetwork = window.__MEDIA_SCOUT_INCLUDE_NETWORK__ !== false;

      function section(name, fn) {
        try {
          const before = found.length;
          fn();
          logs.push(name + ': +' + (found.length - before));
        } catch (error) {
          logs.push(name + ' errore: ' + (error && (error.stack || error.message || String(error))));
        }
      }

      function absolute(value) {
        if (!value || typeof value !== 'string') return null;
        const trimmed = value.trim();
        if (!trimmed || trimmed.indexOf('data:') === 0 || trimmed.indexOf('blob:') === 0) return null;
        try { return new URL(trimmed, pageURL).href; } catch (e) { return null; }
      }

      function clean(value) {
        if (!value) return null;
        return String(value).replace(/\\\\u0026/g, '&').replace(/&amp;/g, '&').replace(/\\\\\\//g, '/');
      }

      function kindFromURL(url, fallback, contentType) {
        const ct = (contentType || '').toLowerCase();
        if (ct.indexOf('gif') >= 0) return 'gif';
        if (ct.indexOf('video') >= 0 || ct.indexOf('mpegurl') >= 0 || ct.indexOf('m3u8') >= 0) return 'video';
        if (ct.indexOf('image') >= 0) return 'image';
        const lowered = (url || '').split('?')[0].toLowerCase();
        if (/\\\\.gif$/.test(lowered)) return 'gif';
        if (/\\\\.(mp4|m4v|mov|webm|m3u8|ts)$/.test(lowered)) return 'video';
        if (/\\\\.(jpg|jpeg|png|webp|avif|heic|tiff|bmp|svg)$/.test(lowered)) return 'image';
        return fallback || 'unknown';
      }

      function add(rawURL, fallbackType, source, meta) {
        const url = absolute(clean(rawURL));
        if (!url || seen.has(url)) return;
        const kind = kindFromURL(url, fallbackType, meta && meta.contentType);
        if (kind === 'unknown' && !fallbackType) return;
        seen.add(url);
        const item = {
          url: url,
          type: kind,
          source: source || 'pagina',
          referer: pageURL
        };
        if (meta && meta.width) item.width = Number(meta.width) || undefined;
        if (meta && meta.height) item.height = Number(meta.height) || undefined;
        if (meta && meta.poster) item.poster = absolute(meta.poster) || undefined;
        if (meta && meta.contentType) item.contentType = String(meta.contentType);
        if (meta && meta.size) item.size = Number(meta.size) || undefined;
        found.push(item);
      }

      function addSrcset(srcset, type, source) {
        if (!srcset) return;
        srcset.split(',').forEach(part => {
          const url = part.trim().split(/\\\\s+/)[0];
          add(url, type, source);
        });
      }

      section('meta', function() {
        document.querySelectorAll('meta[property], meta[name]').forEach(meta => {
          const key = (meta.getAttribute('property') || meta.getAttribute('name') || '').toLowerCase();
          const content = meta.getAttribute('content');
          if (!content) return;
          if (key.indexOf('image') >= 0) add(content, 'image', key);
          if (key.indexOf('video') >= 0 || key.indexOf('player:stream') >= 0) add(content, 'video', key);
        });
      });

      section('video', function() {
        document.querySelectorAll('video').forEach(video => {
          add(video.currentSrc || video.src, 'video', 'video tag', {
            width: video.videoWidth || video.clientWidth,
            height: video.videoHeight || video.clientHeight,
            poster: video.poster
          });
          if (video.poster) add(video.poster, 'image', 'video poster');
          video.querySelectorAll('source').forEach(source => {
            add(source.src || source.getAttribute('src'), 'video', 'video source', {
              width: video.videoWidth || video.clientWidth,
              height: video.videoHeight || video.clientHeight,
              poster: video.poster
            });
          });
        });
      });

      section('images', function() {
        document.querySelectorAll('img').forEach(img => {
          add(img.currentSrc || img.src || img.getAttribute('src'), 'image', 'img tag', {
            width: img.naturalWidth || img.clientWidth,
            height: img.naturalHeight || img.clientHeight
          });
          addSrcset(img.getAttribute('srcset'), 'image', 'img srcset');
        });
      });

      section('source tags', function() {
        document.querySelectorAll('source').forEach(source => {
          const src = source.src || source.getAttribute('src');
          add(src, kindFromURL(src, 'unknown'), 'source tag');
          addSrcset(source.getAttribute('srcset'), 'image', 'source srcset');
        });
      });

      section('links', function() {
        document.querySelectorAll('a[href]').forEach(anchor => {
          const href = anchor.getAttribute('href');
          const url = absolute(href);
          if (url && kindFromURL(url, null) !== 'unknown') add(url, null, 'link diretto');
        });
      });

      section('css background', function() {
        document.querySelectorAll('*').forEach(element => {
          const style = window.getComputedStyle(element);
          const background = style && style.backgroundImage;
          if (!background || background === 'none') return;
          const regex = /url\\\\((['"]?)(.*?)\\\\1\\\\)/g;
          let match;
          while ((match = regex.exec(background)) !== null) add(match[2], 'image', 'css background');
        });
      });

      section('json-ld', function() {
        document.querySelectorAll('script[type="application/ld+json"]').forEach(script => {
          try {
            const json = JSON.parse(script.textContent || '');
            const stack = Array.isArray(json) ? json.slice() : [json];
            let guard = 0;
            while (stack.length && guard < 1000) {
              guard++;
              const node = stack.shift();
              if (!node || typeof node !== 'object') continue;
              ['contentUrl', 'embedUrl', 'thumbnailUrl', 'image', 'url'].forEach(key => {
                const value = node[key];
                if (typeof value === 'string') add(value, null, 'json-ld ' + key);
                if (Array.isArray(value)) value.forEach(v => {
                  if (typeof v === 'string') add(v, null, 'json-ld ' + key);
                  if (v && typeof v === 'object') stack.push(v);
                });
                if (value && typeof value === 'object') stack.push(value);
              });
              Object.keys(node).forEach(key => {
                const value = node[key];
                if (value && typeof value === 'object') stack.push(value);
              });
            }
          } catch (error) {
            logs.push('json-ld parse: ' + String(error.message || error));
          }
        });
      });

      section('html scan', function() {
        const html = document.documentElement ? document.documentElement.outerHTML : '';
        const mediaPattern = /(https?:\\\\/\\\\/[^"'<>\\\\s]+?\\\\.(?:mp4|m4v|mov|webm|m3u8|gif|jpe?g|png|webp|avif)(?:\\\\?[^"'<>\\\\s]*)?)/gi;
        let match;
        while ((match = mediaPattern.exec(html)) !== null) add(match[1], null, 'html scan');
      });

      if (includeNetwork) {
        section('network resources', function() {
          performance.getEntriesByType('resource').forEach(entry => {
            const url = entry.name;
            if (kindFromURL(url, null) !== 'unknown') add(url, null, 'network resource');
          });
        });
      }

      found.sort((a, b) => {
        const score = item => {
          const pixels = (item.width || 0) * (item.height || 0);
          const size = item.size || 0;
          const typeBoost = item.type === 'video' ? 1000000000 : item.type === 'gif' ? 500000000 : 0;
          return typeBoost + pixels + size;
        };
        return score(b) - score(a);
      });

      logs.unshift('Pagina: ' + pageURL);
      logs.push('Totale candidati: ' + found.length);
      return JSON.stringify({ candidates: found.slice(0, 160), logs: logs });
    })();
    """
}

final class ChromeMediaAnalyzer {
    func analyze(url: URL, options: AnalyzerOptions, completion: @escaping (Result<AnalysisReport, Error>) -> Void) {
        guard let helper = BundlePaths.chromeHelperPath() else {
            completion(.failure(NSError(domain: "MediaScout", code: 20, userInfo: [NSLocalizedDescriptionKey: "Helper Chrome non trovato nel bundle o nella cartella scripts."])))
            return
        }
        guard let node = BundlePaths.nodePath() else {
            completion(.failure(NSError(domain: "MediaScout", code: 22, userInfo: [NSLocalizedDescriptionKey: "Node.js non trovato. Installa Node o usa il motore WebKit integrato."])))
            return
        }

        let process = Process()
        process.launchPath = node
        process.arguments = [
            helper,
            "--url", url.absoluteString,
            "--deep-scroll", options.deepScroll ? "1" : "0",
            "--network", options.includeNetworkResources ? "1" : "0",
            "--accept-cookies", options.autoAcceptCookies ? "1" : "0",
            "--limit", "\(options.maxResults)",
            "--headless", "1",
            "--max-ms", "9000"
        ]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        process.terminationHandler = { process in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                let message = stderr.isEmpty ? "Chrome helper terminato con codice \(process.terminationStatus)." : stderr
                completion(.failure(NSError(domain: "MediaScout", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])))
                return
            }

            do {
                var report = try JSONDecoder().decode(AnalysisReport.self, from: data)
                if !stderr.isEmpty {
                    report = AnalysisReport(candidates: report.candidates, logs: report.logs + ["Chrome stderr: \(stderr)"])
                }
                completion(.success(report))
            } catch {
                let raw = String(data: data, encoding: .utf8) ?? ""
                completion(.failure(NSError(domain: "MediaScout", code: 21, userInfo: [NSLocalizedDescriptionKey: "Risposta Chrome non valida: \(error.localizedDescription). \(raw.prefix(500))"])))
            }
        }

        do {
            try process.run()
        } catch {
            completion(.failure(error))
        }
    }
}

enum BundlePaths {
    static func chromeHelperPath() -> String? {
        let bundleURL = Bundle.main.bundleURL
        let bundled = bundleURL.appendingPathComponent("Contents/Resources/chrome-analyzer.js")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let local = cwd.appendingPathComponent("scripts/chrome-analyzer.js")
        if FileManager.default.fileExists(atPath: local.path) {
            return local.path
        }

        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let relative = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/chrome-analyzer.js")
        if FileManager.default.fileExists(atPath: relative.path) {
            return relative.path
        }

        return nil
    }

    static func nodePath() -> String? {
        let candidates = [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            "/opt/local/bin/node",
            "/usr/bin/node"
        ]
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func ffmpegPath() -> String? {
        let candidates = [
            "/usr/local/bin/ffmpeg",
            "/opt/homebrew/bin/ffmpeg",
            "/opt/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func python3Path() -> String? {
        let candidates = [
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3"
        ]
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func youtubeDLPath() -> String? {
        let candidates = [
            "/usr/local/bin/youtube-dl",
            "/opt/homebrew/bin/youtube-dl",
            "/usr/bin/youtube-dl"
        ]
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

enum URLNormalizer {
    static func url(from text: String) -> URL? {
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(text)")
    }
}

enum UserAgents {
    static let safari = "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}

enum FileNameBuilder {
    static func fileName(for candidate: MediaCandidate) -> String {
        guard let url = URL(string: candidate.url) else {
            return "media-\(Int(Date().timeIntervalSince1970)).bin"
        }

        var base = url.deletingPathExtension().lastPathComponent
        if base.isEmpty || base == "/" {
            base = "media-\(Int(Date().timeIntervalSince1970))"
        }

        let ext = url.pathExtension.isEmpty ? defaultExtension(for: candidate) : url.pathExtension
        return "\(sanitized(base)).\(ext)"
    }

    private static func defaultExtension(for candidate: MediaCandidate) -> String {
        if let contentType = candidate.contentType?.lowercased() {
            if contentType.contains("png") { return "png" }
            if contentType.contains("webp") { return "webp" }
            if contentType.contains("gif") { return "gif" }
            if contentType.contains("mp4") { return "mp4" }
            if contentType.contains("webm") { return "webm" }
        }
        switch candidate.type {
        case .image: return "jpg"
        case .gif: return "gif"
        case .video: return "mp4"
        case .unknown: return "bin"
        }
    }

    private static func sanitized(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = text.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return value.isEmpty ? "media" : value
    }
}

final class MediaDownloader {
    func download(url: URL, audioURL: URL?, pageURL: URL?, referer: String?, suggestedName: String, completion: @escaping (Result<URL, Error>) -> Void) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let destination = uniqueDestination(in: downloads, suggestedName: suggestedName)

        if let pageURL = pageURL, isFacebookURL(pageURL), canUseFacebookFallback(pageURL: pageURL) {
            downloadFacebookVideo(pageURL: pageURL, destination: destination, completion: completion)
            return
        }

        guard let audioURL = audioURL else {
            downloadSingle(url: url, referer: referer, destination: destination, completion: completion)
            return
        }

        guard let ffmpeg = BundlePaths.ffmpegPath() else {
            completion(.failure(NSError(domain: "MediaScout", code: 2, userInfo: [NSLocalizedDescriptionKey: "ffmpeg non trovato: non posso unire video e audio."])))
            return
        }

        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("MediaScout-\(UUID().uuidString)", isDirectory: true)
        let videoTemp = tempFolder.appendingPathComponent("video.tmp")
        let audioTemp = tempFolder.appendingPathComponent("audio.tmp")

        do {
            try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        } catch {
            completion(.failure(error))
            return
        }

        downloadSingle(url: url, referer: referer, destination: videoTemp) { [weak self] videoResult in
            guard let self = self else { return }
            switch videoResult {
            case .failure(let error):
                self.cleanup(tempFolder)
                completion(.failure(error))
            case .success:
                self.downloadSingle(url: audioURL, referer: referer, destination: audioTemp) { audioResult in
                    switch audioResult {
                    case .failure(let error):
                        self.cleanup(tempFolder)
                        completion(.failure(error))
                    case .success:
                        self.mux(video: videoTemp, audio: audioTemp, output: destination, ffmpegPath: ffmpeg) { result in
                            self.cleanup(tempFolder)
                            completion(result)
                        }
                    }
                }
            }
        }
    }

    private func downloadSingle(url: URL, referer: String?, destination: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.setValue(UserAgents.safari, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(referer ?? url.absoluteString, forHTTPHeaderField: "Referer")

        let task = URLSession.shared.downloadTask(with: request) { temporaryURL, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let temporaryURL = temporaryURL else {
                completion(.failure(NSError(domain: "MediaScout", code: 1, userInfo: [NSLocalizedDescriptionKey: "File temporaneo non disponibile."])))
                return
            }

            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                completion(.success(destination))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    private func mux(video: URL, audio: URL, output: URL, ffmpegPath: String, completion: @escaping (Result<URL, Error>) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-y",
            "-i", video.path,
            "-i", audio.path,
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-c", "copy",
            "-movflags", "+faststart",
            output.path
        ]

        let stderr = Pipe()
        process.standardError = stderr

        process.terminationHandler = { process in
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if process.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) {
                completion(.success(output))
            } else {
                completion(.failure(NSError(domain: "MediaScout", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "ffmpeg non e riuscito a unire audio e video." : message])))
            }
        }

        do {
            try process.run()
        } catch {
            completion(.failure(error))
        }
    }

    private func downloadFacebookVideo(pageURL: URL, destination: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard
            let python = BundlePaths.python3Path(),
            let youtubeDL = BundlePaths.youtubeDLPath(),
            let ffmpeg = BundlePaths.ffmpegPath()
        else {
            completion(.failure(NSError(domain: "MediaScout", code: 5, userInfo: [NSLocalizedDescriptionKey: "Fallback Facebook non disponibile su questa macchina."])))
            return
        }

        let commandURL = normalizedFacebookWatchURL(from: pageURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [youtubeDL, "--get-url", "--no-warnings", commandURL.absoluteString]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        process.terminationHandler = { [weak self] process in
            guard let self = self else { return }
            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errors = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                completion(.failure(NSError(domain: "MediaScout", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errors.isEmpty ? "youtube-dl non e riuscito a risolvere il video Facebook." : errors])))
                return
            }

            let urls = output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard let videoURL = urls.first.flatMap(URL.init(string:)) else {
                completion(.failure(NSError(domain: "MediaScout", code: 6, userInfo: [NSLocalizedDescriptionKey: "youtube-dl non ha restituito URL scaricabili."])))
                return
            }

            guard urls.count > 1, let audioURL = urls.dropFirst().first.flatMap(URL.init(string:)) else {
                self.downloadSingle(url: videoURL, referer: commandURL.absoluteString, destination: destination, completion: completion)
                return
            }

            let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("MediaScout-Facebook-\(UUID().uuidString)", isDirectory: true)
            let videoTemp = tempFolder.appendingPathComponent("video.mp4")
            let audioTemp = tempFolder.appendingPathComponent("audio.mp4")

            do {
                try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
            } catch {
                completion(.failure(error))
                return
            }

            self.downloadSingle(url: videoURL, referer: commandURL.absoluteString, destination: videoTemp) { videoResult in
                switch videoResult {
                case .failure(let error):
                    self.cleanup(tempFolder)
                    completion(.failure(error))
                case .success:
                    self.downloadSingle(url: audioURL, referer: commandURL.absoluteString, destination: audioTemp) { audioResult in
                        switch audioResult {
                        case .failure(let error):
                            self.cleanup(tempFolder)
                            completion(.failure(error))
                        case .success:
                            self.mux(video: videoTemp, audio: audioTemp, output: destination, ffmpegPath: ffmpeg) { result in
                                self.cleanup(tempFolder)
                                completion(result)
                            }
                        }
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            completion(.failure(error))
        }
    }

    private func canUseFacebookFallback(pageURL: URL) -> Bool {
        BundlePaths.python3Path() != nil && BundlePaths.youtubeDLPath() != nil && BundlePaths.ffmpegPath() != nil && extractFacebookVideoID(from: pageURL) != nil
    }

    private func isFacebookURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "facebook.com" || host.hasSuffix(".facebook.com") || host == "m.facebook.com" || host == "mbasic.facebook.com"
    }

    private func extractFacebookVideoID(from url: URL) -> String? {
        let text = url.absoluteString
        if let match = text.range(of: #"/reel/(\d+)"#, options: .regularExpression) {
            return String(text[match]).components(separatedBy: "/").last
        }
        if let match = text.range(of: #"/videos/(?:[^/]+/)?(\d+)"#, options: .regularExpression) {
            let value = String(text[match])
            return value.components(separatedBy: "/").last
        }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let value = components.queryItems?.first(where: { $0.name == "v" })?.value,
           !value.isEmpty {
            return value
        }
        return nil
    }

    private func normalizedFacebookWatchURL(from url: URL) -> URL {
        guard let id = extractFacebookVideoID(from: url) else { return url }
        return URL(string: "https://www.facebook.com/watch/?v=\(id)") ?? url
    }

    private func cleanup(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    private func uniqueDestination(in folder: URL, suggestedName: String) -> URL {
        let base = (suggestedName as NSString).deletingPathExtension
        let ext = (suggestedName as NSString).pathExtension
        var destination = folder.appendingPathComponent(suggestedName)
        var index = 2

        while FileManager.default.fileExists(atPath: destination.path) {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            destination = folder.appendingPathComponent(name)
            index += 1
        }

        return destination
    }
}

final class GIFConverter {
    func convert(request: GIFConversionRequest, downloader: MediaDownloader, completion: @escaping (Result<URL, Error>) -> Void) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser

        let outputName = self.gifName(for: request.sourceText)
        let outputURL = uniqueDestination(in: downloads, suggestedName: outputName)

        prepareSourceVideo(request: request) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let prepared):
                self.renderGIF(from: prepared.videoURL, outputURL: outputURL, request: request) { renderResult in
                    if let tempFolder = prepared.cleanupFolder {
                        try? FileManager.default.removeItem(at: tempFolder)
                    }
                    completion(renderResult)
                }
            }
        }
    }

    private func prepareSourceVideo(request: GIFConversionRequest, completion: @escaping (Result<(videoURL: URL, cleanupFolder: URL?), Error>) -> Void) {
        let source = request.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if FileManager.default.fileExists(atPath: source) {
            completion(.success((URL(fileURLWithPath: source), nil)))
            return
        }

        guard let remoteURL = URL(string: source), remoteURL.scheme != nil else {
            completion(.failure(NSError(domain: "MediaScout", code: 30, userInfo: [NSLocalizedDescriptionKey: "Sorgente GIF non valida. Usa una URL completa o un file locale."])))
            return
        }

        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("MediaScout-GIF-\(UUID().uuidString)", isDirectory: true)
        let tempVideo = tempFolder.appendingPathComponent("source.mp4")

        do {
            try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        } catch {
            completion(.failure(error))
            return
        }

        if let candidate = request.sourceCandidate {
            if let pageURL = request.pageURL, isFacebookURL(pageURL), canUseFacebookFallback(pageURL: pageURL) {
                materializeFacebookVideo(pageURL: pageURL, destination: tempVideo) { result in
                    switch result {
                    case .success(let url):
                        completion(.success((url, tempFolder)))
                    case .failure(let error):
                        try? FileManager.default.removeItem(at: tempFolder)
                        completion(.failure(error))
                    }
                }
                return
            }

            if let audioURL = candidate.audioURL.flatMap(URL.init(string:)) {
                muxRemoteVideoAndAudio(videoURL: remoteURL, audioURL: audioURL, referer: candidate.referer ?? request.pageURL?.absoluteString, destination: tempVideo) { result in
                    switch result {
                    case .success(let url):
                        completion(.success((url, tempFolder)))
                    case .failure(let error):
                        try? FileManager.default.removeItem(at: tempFolder)
                        completion(.failure(error))
                    }
                }
                return
            }
        }

        downloadSingle(url: remoteURL, referer: request.sourceCandidate?.referer ?? request.pageURL?.absoluteString, destination: tempVideo) { result in
            switch result {
            case .success(let url):
                completion(.success((url, tempFolder)))
            case .failure(let error):
                try? FileManager.default.removeItem(at: tempFolder)
                completion(.failure(error))
            }
        }
    }

    private func renderGIF(from sourceURL: URL, outputURL: URL, request: GIFConversionRequest, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let ffmpeg = BundlePaths.ffmpegPath() else {
            completion(.failure(NSError(domain: "MediaScout", code: 31, userInfo: [NSLocalizedDescriptionKey: "ffmpeg non trovato: conversione GIF non disponibile."])))
            return
        }

        let paletteURL = FileManager.default.temporaryDirectory.appendingPathComponent("mediascout-palette-\(UUID().uuidString).png")
        let baseFilter = buildBaseGIFFilter(request: request)
        let paletteProcess = Process()
        paletteProcess.executableURL = URL(fileURLWithPath: ffmpeg)
        paletteProcess.arguments = [
            "-y",
            "-i", sourceURL.path,
            "-vf", "\(baseFilter),palettegen=max_colors=\(request.paletteSize.rawValue):reserve_transparent=1",
            paletteURL.path
        ]

        let palettePipe = Pipe()
        paletteProcess.standardError = palettePipe

        paletteProcess.terminationHandler = { process in
            let paletteError = String(data: palettePipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: paletteURL.path) else {
                try? FileManager.default.removeItem(at: paletteURL)
                completion(.failure(NSError(domain: "MediaScout", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: paletteError.isEmpty ? "Impossibile generare la tavolozza GIF." : paletteError])))
                return
            }

            let renderProcess = Process()
            renderProcess.executableURL = URL(fileURLWithPath: ffmpeg)
            renderProcess.arguments = [
                "-y",
                "-i", sourceURL.path,
                "-i", paletteURL.path,
                "-lavfi", "\(baseFilter)[x];[x][1:v]\(self.paletteUseFilter(request: request))",
                "-gifflags", request.frameDifferencing ? "+transdiff" : "-transdiff",
                outputURL.path
            ]

            let renderPipe = Pipe()
            renderProcess.standardError = renderPipe
            renderProcess.terminationHandler = { render in
                let renderError = String(data: renderPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                try? FileManager.default.removeItem(at: paletteURL)
                if render.terminationStatus == 0, FileManager.default.fileExists(atPath: outputURL.path) {
                    completion(.success(outputURL))
                } else {
                    completion(.failure(NSError(domain: "MediaScout", code: Int(render.terminationStatus), userInfo: [NSLocalizedDescriptionKey: renderError.isEmpty ? "Conversione GIF non riuscita." : renderError])))
                }
            }

            do {
                try renderProcess.run()
            } catch {
                try? FileManager.default.removeItem(at: paletteURL)
                completion(.failure(error))
            }
        }

        do {
            try paletteProcess.run()
        } catch {
            completion(.failure(error))
        }
    }

    private func buildBaseGIFFilter(request: GIFConversionRequest) -> String {
        var parts: [String] = []
        let start = max(request.trimStart ?? 0, 0)
        if let end = request.trimEnd, end > start {
            parts.append("trim=start=\(start):end=\(end)")
            parts.append("setpts=PTS-STARTPTS")
        } else if start > 0 {
            parts.append("trim=start=\(start)")
            parts.append("setpts=PTS-STARTPTS")
        }

        parts.append("fps=\(request.fps)")
        parts.append("scale=trunc(iw*\(request.scalePercent)/100/2)*2:trunc(ih*\(request.scalePercent)/100/2)*2:flags=lanczos")

        if request.lossyPercent > 0 {
            let sigma = String(format: "%.2f", Double(request.lossyPercent) / 28.0)
            parts.append("gblur=sigma=\(sigma)")
        }

        if request.dropDuplicateFrames {
            parts.append("mpdecimate")
            parts.append("setpts=N/FRAME_RATE/TB")
        }

        return parts.joined(separator: ",")
    }

    private func paletteUseFilter(request: GIFConversionRequest) -> String {
        var parts = ["paletteuse=dither=\(request.ditherStyle.rawValue)"]
        if request.ditherStyle == .bayer {
            let scale = max(0, min(5, 5 - Int((Double(request.ditherIntensity) / 100.0) * 5.0)))
            parts.append("bayer_scale=\(scale)")
        }
        if request.frameDifferencing {
            parts.append("diff_mode=rectangle")
        }
        return parts.joined(separator: ":")
    }

    private func materializeFacebookVideo(pageURL: URL, destination: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard
            let python = BundlePaths.python3Path(),
            let youtubeDL = BundlePaths.youtubeDLPath(),
            let ffmpeg = BundlePaths.ffmpegPath()
        else {
            completion(.failure(NSError(domain: "MediaScout", code: 32, userInfo: [NSLocalizedDescriptionKey: "Fallback Facebook GIF non disponibile."])))
            return
        }

        let commandURL = normalizedFacebookWatchURL(from: pageURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [youtubeDL, "--get-url", "--no-warnings", commandURL.absoluteString]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        process.terminationHandler = { process in
            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errors = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                completion(.failure(NSError(domain: "MediaScout", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errors.isEmpty ? "youtube-dl non ha risolto il video Facebook." : errors])))
                return
            }

            let urls = output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard let videoURL = urls.first.flatMap(URL.init(string:)) else {
                completion(.failure(NSError(domain: "MediaScout", code: 33, userInfo: [NSLocalizedDescriptionKey: "youtube-dl non ha restituito URL per il video Facebook."])))
                return
            }

            guard urls.count > 1, let audioURL = urls.dropFirst().first.flatMap(URL.init(string:)) else {
                self.downloadSingle(url: videoURL, referer: commandURL.absoluteString, destination: destination, completion: completion)
                return
            }

            self.muxRemoteVideoAndAudio(videoURL: videoURL, audioURL: audioURL, referer: commandURL.absoluteString, destination: destination, ffmpegPath: ffmpeg, completion: completion)
        }

        do {
            try process.run()
        } catch {
            completion(.failure(error))
        }
    }

    private func muxRemoteVideoAndAudio(videoURL: URL, audioURL: URL, referer: String?, destination: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let ffmpeg = BundlePaths.ffmpegPath() else {
            completion(.failure(NSError(domain: "MediaScout", code: 34, userInfo: [NSLocalizedDescriptionKey: "ffmpeg non trovato per il merge video/audio."])))
            return
        }
        muxRemoteVideoAndAudio(videoURL: videoURL, audioURL: audioURL, referer: referer, destination: destination, ffmpegPath: ffmpeg, completion: completion)
    }

    private func muxRemoteVideoAndAudio(videoURL: URL, audioURL: URL, referer: String?, destination: URL, ffmpegPath: String, completion: @escaping (Result<URL, Error>) -> Void) {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("MediaScout-GIFSource-\(UUID().uuidString)", isDirectory: true)
        let videoTemp = tempFolder.appendingPathComponent("video.mp4")
        let audioTemp = tempFolder.appendingPathComponent("audio.mp4")

        do {
            try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        } catch {
            completion(.failure(error))
            return
        }

        downloadSingle(url: videoURL, referer: referer, destination: videoTemp) { result in
            switch result {
            case .failure(let error):
                try? FileManager.default.removeItem(at: tempFolder)
                completion(.failure(error))
            case .success:
                self.downloadSingle(url: audioURL, referer: referer, destination: audioTemp) { audioResult in
                    switch audioResult {
                    case .failure(let error):
                        try? FileManager.default.removeItem(at: tempFolder)
                        completion(.failure(error))
                    case .success:
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: ffmpegPath)
                        process.arguments = [
                            "-y",
                            "-i", videoTemp.path,
                            "-i", audioTemp.path,
                            "-map", "0:v:0",
                            "-map", "1:a:0",
                            "-c", "copy",
                            "-movflags", "+faststart",
                            destination.path
                        ]
                        let pipe = Pipe()
                        process.standardError = pipe
                        process.terminationHandler = { proc in
                            let message = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                            try? FileManager.default.removeItem(at: tempFolder)
                            if proc.terminationStatus == 0, FileManager.default.fileExists(atPath: destination.path) {
                                completion(.success(destination))
                            } else {
                                completion(.failure(NSError(domain: "MediaScout", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "Merge video/audio fallito." : message])))
                            }
                        }
                        do {
                            try process.run()
                        } catch {
                            try? FileManager.default.removeItem(at: tempFolder)
                            completion(.failure(error))
                        }
                    }
                }
            }
        }
    }

    private func downloadSingle(url: URL, referer: String?, destination: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.setValue(UserAgents.safari, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(referer ?? url.absoluteString, forHTTPHeaderField: "Referer")

        let task = URLSession.shared.downloadTask(with: request) { temporaryURL, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let temporaryURL = temporaryURL else {
                completion(.failure(NSError(domain: "MediaScout", code: 35, userInfo: [NSLocalizedDescriptionKey: "File sorgente GIF non disponibile."])))
                return
            }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                completion(.success(destination))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    private func gifName(for source: String) -> String {
        if let url = URL(string: source), url.scheme != nil {
            let base = url.deletingPathExtension().lastPathComponent
            return "\(base.isEmpty ? "converted" : base).gif"
        }
        let base = URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent
        return "\(base.isEmpty ? "converted" : base).gif"
    }

    private func uniqueDestination(in folder: URL, suggestedName: String) -> URL {
        let base = (suggestedName as NSString).deletingPathExtension
        let ext = (suggestedName as NSString).pathExtension
        var destination = folder.appendingPathComponent(suggestedName)
        var index = 2

        while FileManager.default.fileExists(atPath: destination.path) {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            destination = folder.appendingPathComponent(name)
            index += 1
        }

        return destination
    }

    private func canUseFacebookFallback(pageURL: URL) -> Bool {
        BundlePaths.python3Path() != nil && BundlePaths.youtubeDLPath() != nil && BundlePaths.ffmpegPath() != nil && extractFacebookVideoID(from: pageURL) != nil
    }

    private func isFacebookURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "facebook.com" || host.hasSuffix(".facebook.com") || host == "m.facebook.com" || host == "mbasic.facebook.com"
    }

    private func extractFacebookVideoID(from url: URL) -> String? {
        let text = url.absoluteString
        if let match = text.range(of: #"/reel/(\d+)"#, options: .regularExpression) {
            return String(text[match]).components(separatedBy: "/").last
        }
        if let match = text.range(of: #"/videos/(?:[^/]+/)?(\d+)"#, options: .regularExpression) {
            let value = String(text[match])
            return value.components(separatedBy: "/").last
        }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let value = components.queryItems?.first(where: { $0.name == "v" })?.value,
           !value.isEmpty {
            return value
        }
        return nil
    }

    private func normalizedFacebookWatchURL(from url: URL) -> URL {
        guard let id = extractFacebookVideoID(from: url) else { return url }
        return URL(string: "https://www.facebook.com/watch/?v=\(id)") ?? url
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        let contentView = ContentView(state: state)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MediaScout"
        window.minSize = NSSize(width: 1120, height: 760)
        window.center()
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "Chiudi MediaScout", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Modifica")
        editItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "Annulla", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Ripristina", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Taglia", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copia", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Incolla", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Seleziona tutto", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

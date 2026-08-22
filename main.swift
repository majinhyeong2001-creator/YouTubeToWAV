import SwiftUI
import AVKit
import AVFoundation
import AppKit

@main
struct YouTubeToWAVApp: App {
    var body: some Scene {
        WindowGroup("YouTube → WAV") {
            ContentView()
                .frame(minWidth: 950, minHeight: 700)
        }
    }
}

// MARK: - Models

enum RangeMode: String, CaseIterable, Identifiable {
    case all = "처음부터 끝까지"
    case fromStart = "처음부터 → 종료점"
    case toEnd = "시작점 → 끝까지"
    case custom = "직접 지정"

    var id: String { rawValue }
}

struct VideoInfo {
    let url: String
    let title: String
    let streamURL: URL?
    let duration: Double
}

struct DownloadItem: Identifiable {
    let id = UUID()
    let url: String
    var title: String = ""
    var progress: Double = 0
    var status: String = "대기"
}

// MARK: - Utility

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else {
        return "00:00:00"
    }

    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60

    return String(format: "%02d:%02d:%02d", h, m, s)
}

func parseTime(_ value: String) -> Double? {
    let parts = value.split(separator: ":")

    guard parts.count == 3,
          let h = Double(parts[0]),
          let m = Double(parts[1]),
          let s = Double(parts[2]),
          h >= 0,
          m >= 0,
          m < 60,
          s >= 0,
          s < 60 else {
        return nil
    }

    return h * 3600 + m * 60 + s
}

// MARK: - yt-dlp

final class YTDLP {

    static let shared = YTDLP()

    private let executableCandidates = [
        "/opt/homebrew/bin/yt-dlp",
        "/usr/local/bin/yt-dlp",
        "/usr/bin/yt-dlp"
    ]

    private var executable: String? {
        executableCandidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    func run(
        arguments: [String],
        completion: @escaping (Int32, String, String) -> Void
    ) {
        guard let executable else {
            completion(
                -1,
                "",
                """
                yt-dlp를 찾을 수 없습니다.

                Homebrew를 사용한다면:

                brew install yt-dlp ffmpeg
                """
            )
            return
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()

                let outputData =
                    stdout.fileHandleForReading.readDataToEndOfFile()

                let errorData =
                    stderr.fileHandleForReading.readDataToEndOfFile()

                process.waitUntilExit()

                let output =
                    String(
                        data: outputData,
                        encoding: .utf8
                    ) ?? ""

                let error =
                    String(
                        data: errorData,
                        encoding: .utf8
                    ) ?? ""

                DispatchQueue.main.async {
                    completion(
                        process.terminationStatus,
                        output,
                        error
                    )
                }

            } catch {
                DispatchQueue.main.async {
                    completion(
                        -1,
                        "",
                        error.localizedDescription
                    )
                }
            }
        }
    }

    func videoInfo(
        url: String,
        completion: @escaping (Result<VideoInfo, Error>) -> Void
    ) {
        run(
            arguments: [
                "--dump-single-json",
                "--no-playlist",
                "--skip-download",
                "--no-warnings",
                url
            ]
        ) { status, output, error in

            guard status == 0 else {
                completion(
                    .failure(
                        NSError(
                            domain: "YTDLP",
                            code: Int(status),
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    error.isEmpty
                                    ? "영상 정보를 가져오지 못했습니다."
                                    : error
                            ]
                        )
                    )
                )
                return
            }

            guard
                let data = output.data(using: .utf8),
                let json =
                    try? JSONSerialization.jsonObject(
                        with: data
                    ) as? [String: Any]
            else {
                completion(
                    .failure(
                        NSError(
                            domain: "YTDLP",
                            code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "영상 정보를 분석하지 못했습니다."
                            ]
                        )
                    )
                )
                return
            }

            let title =
                json["title"] as? String
                ?? "YouTube Audio"

            let duration =
                json["duration"] as? Double
                ?? 0

            self.run(
                arguments: [
                    "-g",
                    "--no-playlist",
                    "-f",
                    "best[ext=mp4][vcodec^=avc1]/best[ext=mp4]/best",
                    url
                ]
            ) { status, output, error in

                guard status == 0 else {
                    completion(
                        .success(
                            VideoInfo(
                                url: url,
                                title: title,
                                streamURL: nil,
                                duration: duration
                            )
                        )
                    )
                    return
                }

                let streamURL =
                    output
                        .split(separator: "\n")
                        .first
                        .flatMap {
                            URL(string: String($0))
                        }

                completion(
                    .success(
                        VideoInfo(
                            url: url,
                            title: title,
                            streamURL: streamURL,
                            duration: duration
                        )
                    )
                )
            }
        }
    }

    func downloadWAV(
        url: String,
        outputFolder: URL,
        start: Double?,
        end: Double?,
        completion: @escaping (Bool, String) -> Void
    ) {
        var arguments: [String] = [
            "--no-playlist",
            "--newline",
            "--progress",
            "-x",
            "--audio-format",
            "wav",
            "--audio-quality",
            "0"
        ]

        if let start, let end {
            arguments += [
                "--download-sections",
                "*\(formatTime(start))-\(formatTime(end))"
            ]
        } else if let start {
            arguments += [
                "--download-sections",
                "*\(formatTime(start))-inf"
            ]
        } else if let end {
            arguments += [
                "--download-sections",
                "*0-\(formatTime(end))"
            ]
        }

        let outputTemplate =
            outputFolder
                .appendingPathComponent("%(title)s.%(ext)s")
                .path

        arguments += [
            "-o",
            outputTemplate,
            url
        ]

        run(arguments: arguments) { status, _, error in
            completion(
                status == 0,
                status == 0 ? "완료" : error
            )
        }
    }
}

// MARK: - Range Slider

struct RangeSlider: View {

    @Binding var lowerValue: Double
    @Binding var upperValue: Double

    let range: ClosedRange<Double>

    private let knobSize: CGFloat = 20

    var body: some View {
        GeometryReader { geometry in

            let width = geometry.size.width
            let minimum = range.lowerBound
            let maximum = range.upperBound

            let lowerX =
                position(
                    value: lowerValue,
                    width: width,
                    minimum: minimum,
                    maximum: maximum
                )

            let upperX =
                position(
                    value: upperValue,
                    width: width,
                    minimum: minimum,
                    maximum: maximum
                )

            ZStack(alignment: .leading) {

                Capsule()
                    .fill(Color.gray.opacity(0.25))
                    .frame(height: 6)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(
                        width: max(
                            0,
                            upperX - lowerX
                        ),
                        height: 7
                    )
                    .offset(x: lowerX)

                Circle()
                    .fill(Color.white)
                    .overlay(
                        Circle()
                            .stroke(
                                Color.accentColor,
                                lineWidth: 2
                            )
                    )
                    .frame(
                        width: knobSize,
                        height: knobSize
                    )
                    .offset(
                        x: lowerX - knobSize / 2
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { value in

                                let newValue =
                                    valueToPosition(
                                        value.location.x,
                                        width: width,
                                        minimum: minimum,
                                        maximum: maximum
                                    )

                                lowerValue =
                                    Swift.min(
                                        Swift.max(
                                            newValue,
                                            minimum
                                        ),
                                        upperValue
                                    )
                            }
                    )

                Circle()
                    .fill(Color.white)
                    .overlay(
                        Circle()
                            .stroke(
                                Color.accentColor,
                                lineWidth: 2
                            )
                    )
                    .frame(
                        width: knobSize,
                        height: knobSize
                    )
                    .offset(
                        x: upperX - knobSize / 2
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { value in

                                let newValue =
                                    valueToPosition(
                                        value.location.x,
                                        width: width,
                                        minimum: minimum,
                                        maximum: maximum
                                    )

                                upperValue =
                                    Swift.max(
                                        Swift.min(
                                            newValue,
                                            maximum
                                        ),
                                        lowerValue
                                    )
                            }
                    )
            }
        }
        .frame(height: 30)
    }

    private func position(
        value: Double,
        width: CGFloat,
        minimum: Double,
        maximum: Double
    ) -> CGFloat {

        guard maximum > minimum else {
            return 0
        }

        return CGFloat(
            (value - minimum)
            / (maximum - minimum)
        ) * width
    }

    private func valueToPosition(
        _ x: CGFloat,
        width: CGFloat,
        minimum: Double,
        maximum: Double
    ) -> Double {

        guard width > 0 else {
            return minimum
        }

        let ratio =
            Swift.min(
                Swift.max(
                    x / width,
                    0
                ),
                1
            )

        return minimum
            + Double(ratio)
            * (maximum - minimum)
    }
}

// MARK: - Video Player

struct PlayerView: NSViewRepresentable {

    let player: AVPlayer

    func makeNSView(
        context: Context
    ) -> AVPlayerView {

        let view = AVPlayerView()

        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true

        return view
    }

    func updateNSView(
        _ nsView: AVPlayerView,
        context: Context
    ) {
        nsView.player = player
    }
}

// MARK: - Main View

struct ContentView: View {

    @State private var urls = ""

    @State private var player = AVPlayer()

    @State private var videoInfo: VideoInfo?

    @State private var duration: Double = 0
    @State private var currentTime: Double = 0

    @State private var startTime: Double = 0
    @State private var endTime: Double = 0

    @State private var rangeMode: RangeMode = .all

    @State private var startText = "00:00:00"
    @State private var endText = "00:00:00"

    @State private var outputFolder =
        FileManager.default.urls(
            for: .musicDirectory,
            in: .userDomainMask
        ).first
        ?? FileManager.default.homeDirectoryForCurrentUser

    @State private var loading = false
    @State private var downloading = false
    @State private var message = ""

    @State private var queue: [DownloadItem] = []

    let timer =
        Timer.publish(
            every: 0.1,
            on: .main,
            in: .common
        )
        .autoconnect()

    var body: some View {

        VStack(spacing: 0) {

            // Header

            HStack {

                Text("YouTube → WAV")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button("저장 폴더 선택") {
                    selectFolder()
                }

                Text(outputFolder.path)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 300)
            }
            .padding()

            Divider()

            // URL

            VStack(
                alignment: .leading,
                spacing: 8
            ) {

                Text("YouTube URL")
                    .font(.headline)

                TextEditor(text: $urls)
                    .font(
                        .system(
                            .body,
                            design: .monospaced
                        )
                    )
                    .frame(height: 90)
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: 6
                        )
                        .stroke(
                            Color.gray.opacity(0.3)
                        )
                    )

                HStack {

                    Text(
                        "여러 URL은 줄바꿈으로 구분합니다."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        loadVideo()
                    } label: {

                        if loading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("영상 불러오기")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()

            Divider()

            // Player

            VStack(spacing: 8) {

                if videoInfo != nil {

                    PlayerView(player: player)
                        .frame(
                            minHeight: 300,
                            maxHeight: 400
                        )
                        .background(Color.black)

                } else {

                    ZStack {

                        Rectangle()
                            .fill(
                                Color.black.opacity(0.08)
                            )

                        VStack(spacing: 10) {

                            Image(
                                systemName:
                                    "play.rectangle"
                            )
                            .font(
                                .system(size: 40)
                            )

                            Text(
                                "영상을 불러오면 미리보기가 표시됩니다."
                            )
                            .foregroundStyle(
                                .secondary
                            )
                        }
                    }
                    .frame(height: 300)
                }
            }
            .padding(.horizontal)

            // Timeline

            VStack(spacing: 8) {

                HStack {

                    Text(
                        formatTime(currentTime)
                    )
                    .monospacedDigit()

                    Spacer()

                    Text(
                        formatTime(duration)
                    )
                    .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                RangeSlider(
                    lowerValue: $startTime,
                    upperValue: $endTime,
                    range: 0...max(
                        duration,
                        1
                    )
                )
                .onChange(of: startTime) {
                    startText =
                        formatTime(startTime)
                }
                .onChange(of: endTime) {
                    endText =
                        formatTime(endTime)
                }

                HStack {

                    Button(
                        "현재 위치를 시작점으로"
                    ) {
                        setStartToCurrent()
                    }

                    Button(
                        "현재 위치를 종료점으로"
                    ) {
                        setEndToCurrent()
                    }

                    Spacer()

                    Button("선택 구간 재생") {
                        playSelectedRange()
                    }
                }
                .font(.caption)
            }
            .padding()

            Divider()

            // Range controls

            VStack(
                alignment: .leading,
                spacing: 12
            ) {

                Picker(
                    "구간",
                    selection: $rangeMode
                ) {

                    ForEach(
                        RangeMode.allCases
                    ) { mode in

                        Text(mode.rawValue)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: rangeMode) {
                    applyRangeMode(rangeMode)
                }

                HStack {

                    VStack(
                        alignment: .leading
                    ) {

                        Text("시작")
                            .font(.caption)
                            .foregroundStyle(
                                .secondary
                            )

                        TextField(
                            "HH:MM:SS",
                            text: $startText
                        )
                        .textFieldStyle(
                            .roundedBorder
                        )
                        .frame(width: 130)
                        .onSubmit {
                            updateStartFromText()
                        }
                    }

                    Text("→")
                        .foregroundStyle(
                            .secondary
                        )

                    VStack(
                        alignment: .leading
                    ) {

                        Text("종료")
                            .font(.caption)
                            .foregroundStyle(
                                .secondary
                            )

                        TextField(
                            "HH:MM:SS",
                            text: $endText
                        )
                        .textFieldStyle(
                            .roundedBorder
                        )
                        .frame(width: 130)
                        .onSubmit {
                            updateEndFromText()
                        }
                    }

                    Spacer()

                    Button {

                        download()

                    } label: {

                        if downloading {

                            ProgressView()
                                .controlSize(
                                    .small
                                )

                        } else {

                            Label(
                                "WAV 다운로드",
                                systemImage:
                                    "arrow.down.circle"
                            )
                        }
                    }
                    .buttonStyle(
                        .borderedProminent
                    )
                    .disabled(
                        videoInfo == nil
                        || downloading
                    )
                }
            }
            .padding()

            Divider()

            // Queue

            VStack(
                alignment: .leading
            ) {

                HStack {

                    Text("다운로드 대기열")
                        .font(.headline)

                    Spacer()

                    if !message.isEmpty {

                        Text(message)
                            .font(.caption)
                            .foregroundStyle(
                                .secondary
                            )
                    }
                }

                ScrollView {

                    VStack(spacing: 6) {

                        ForEach(queue) { item in

                            HStack {

                                Image(
                                    systemName:
                                        statusIcon(
                                            item.status
                                        )
                                )

                                VStack(
                                    alignment:
                                        .leading
                                ) {

                                    Text(
                                        item.title.isEmpty
                                        ? item.url
                                        : item.title
                                    )
                                    .lineLimit(1)

                                    Text(
                                        item.status
                                    )
                                    .font(.caption)
                                    .foregroundStyle(
                                        .secondary
                                    )
                                }

                                Spacer()

                                if item.progress > 0 &&
                                    item.progress < 1 {

                                    ProgressView(
                                        value:
                                            item.progress
                                    )
                                    .frame(
                                        width: 120
                                    )
                                }
                            }
                            .padding(8)
                            .background(
                                Color.gray.opacity(
                                    0.08
                                )
                            )
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: 6
                                )
                            )
                        }
                    }
                }
            }
            .padding()
        }
        .onReceive(timer) { _ in
            updateCurrentTime()
        }
    }

    // MARK: Player

    private func updateCurrentTime() {

        guard player.currentItem != nil else {
            return
        }

        let seconds =
            player.currentTime().seconds

        guard seconds.isFinite else {
            return
        }

        currentTime = seconds
    }

    private func loadVideo() {

        guard
            let urlString =
                urls
                    .split(separator: "\n")
                    .map {
                        $0.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                    }
                    .first(where: {
                        !$0.isEmpty
                    })
        else {
            return
        }

        loading = true
        message =
            "영상 정보를 가져오는 중..."

        YTDLP.shared.videoInfo(
            url: urlString
        ) { result in

            loading = false

            switch result {

            case .success(let info):

                videoInfo = info

                duration = info.duration

                startTime = 0
                endTime = info.duration

                startText =
                    formatTime(0)

                endText =
                    formatTime(info.duration)

                if let streamURL =
                    info.streamURL {

                    let item =
                        AVPlayerItem(
                            url: streamURL
                        )

                    player.replaceCurrentItem(
                        with: item
                    )

                    message =
                        "영상 준비 완료"

                } else {

                    message =
                        "미리보기 스트림을 가져오지 못했습니다."
                }

            case .failure(let error):

                message =
                    "오류: \(error.localizedDescription)"
            }
        }
    }

    private func playSelectedRange() {

        let start =
            CMTime(
                seconds: startTime,
                preferredTimescale: 600
            )

        player.seek(to: start)
        player.play()

        let interval =
            CMTime(
                seconds: 0.1,
                preferredTimescale: 600
            )

        var observer: Any?

        observer =
            player.addPeriodicTimeObserver(
                forInterval: interval,
                queue: .main
            ) { [weak player] time in

                if time.seconds >= endTime {

                    player?.pause()

                    if let observer {
                        player?.removeTimeObserver(
                            observer
                        )
                    }
                }
            }
    }

    // MARK: Range

    private func setStartToCurrent() {

        let value =
            Swift.min(
                currentTime,
                endTime
            )

        startTime = value
        startText =
            formatTime(value)
    }

    private func setEndToCurrent() {

        let value =
            Swift.max(
                currentTime,
                startTime
            )

        endTime = value
        endText =
            formatTime(value)
    }

    private func applyRangeMode(
        _ mode: RangeMode
    ) {

        switch mode {

        case .all:

            startTime = 0
            endTime = duration

        case .fromStart:

            startTime = 0

        case .toEnd:

            endTime = duration

        case .custom:

            break
        }

        startText =
            formatTime(startTime)

        endText =
            formatTime(endTime)
    }

    private func updateStartFromText() {

        guard
            let value =
                parseTime(startText)
        else {
            startText =
                formatTime(startTime)
            return
        }

        startTime =
            Swift.min(
                Swift.max(
                    0,
                    value
                ),
                endTime
            )

        startText =
            formatTime(startTime)
    }

    private func updateEndFromText() {

        guard
            let value =
                parseTime(endText)
        else {
            endText =
                formatTime(endTime)
            return
        }

        endTime =
            Swift.max(
                Swift.min(
                    duration,
                    value
                ),
                startTime
            )

        endText =
            formatTime(endTime)
    }

    // MARK: Folder

    private func selectFolder() {

        let panel =
            NSOpenPanel()

        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK,
           let url = panel.url {

            outputFolder = url
        }
    }

    // MARK: Download

    private func download() {

        let urlList =
            urls
                .split(separator: "\n")
                .map {
                    $0.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                }
                .filter {
                    !$0.isEmpty
                }

        guard !urlList.isEmpty else {
            return
        }

        downloading = true

        message =
            "\(urlList.count)개 다운로드 준비"

        queue =
            urlList.map {
                DownloadItem(url: $0)
            }

        downloadNext(index: 0)
    }

    private func downloadNext(
        index: Int
    ) {

        guard index < queue.count else {

            downloading = false

            message =
                "모든 다운로드가 완료되었습니다."

            return
        }

        queue[index].status =
            "영상 정보 확인 중..."

        let url =
            queue[index].url

        YTDLP.shared.videoInfo(
            url: url
        ) { result in

            switch result {

            case .failure(let error):

                queue[index].status =
                    "실패: \(error.localizedDescription)"

                downloadNext(
                    index: index + 1
                )

            case .success(let info):

                queue[index].title =
                    info.title

                queue[index].status =
                    "WAV 다운로드 중..."

                let start: Double?
                let end: Double?

                switch rangeMode {

                case .all:

                    start = nil
                    end = nil

                case .fromStart:

                    start = nil
                    end = endTime

                case .toEnd:

                    start = startTime
                    end = nil

                case .custom:

                    start = startTime
                    end = endTime
                }

                YTDLP.shared.downloadWAV(
                    url: url,
                    outputFolder: outputFolder,
                    start: start,
                    end: end
                ) { success, result in

                    if success {

                        queue[index].progress = 1
                        queue[index].status =
                            "완료"

                    } else {

                        queue[index].status =
                            "실패: \(result)"
                    }

                    downloadNext(
                        index: index + 1
                    )
                }
            }
        }
    }

    // MARK: UI

    private func statusIcon(
        _ status: String
    ) -> String {

        if status == "완료" {
            return "checkmark.circle.fill"
        }

        if status.contains("실패") {
            return "xmark.circle.fill"
        }

        if status.contains("중") {
            return "arrow.down.circle"
        }

        return "circle"
    }
}

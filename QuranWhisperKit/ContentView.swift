//  For licensing see accompanying LICENSE.md file.
//  Copyright © 2024 Argmax, Inc. All rights reserved.

import SwiftUI
import WhisperKit
import Foundation
import AVFoundation
import CoreML

struct ContentView: View {
    @State private var whisperKit: WhisperKit?
    @State private var isRecording: Bool = false
    @State private var isTranscribing: Bool = false
    @State private var transcribedText: String = ""
    
    // Model management
    @State private var modelStorage: String = "huggingface/models/fazalshaikh123/ultra-fast-tarteel-coreml"
    @State private var repoName: String = "fazalshaikh123/ultra-fast-tarteel-coreml"
    @State private var modelState: ModelState = .unloaded
    @State private var localModelPath: String = ""
    @State private var loadingProgressValue: Float = 0.0
    @State private var specializationProgressRatio: Float = 0.7
    
    // Audio processing
    @State private var bufferEnergy: [Float] = []
    @State private var bufferSeconds: Double = 0
    @State private var lastBufferSize: Int = 0
    @State private var transcriptionTask: Task<Void, Never>?
    @State private var scrollPosition: Int?
    
    // Transcription settings (fixed for Arabic Quran)
    private let selectedLanguage: String = "arabic"
    private let silenceThreshold: Double = 0.3
    private let useVAD: Bool = true
    private let encoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine
    private let decoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine
    
    func getComputeOptions() -> ModelComputeOptions {
        return ModelComputeOptions(audioEncoderCompute: encoderComputeUnits, textDecoderCompute: decoderComputeUnits)
    }
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                gradient: Gradient(colors: [Color.blue.opacity(0.1), Color.white]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            if modelState == .loaded {
                // Main recording view
                VStack(spacing: 0) {
                    Text("اقرأ القرآن، بصوت واضح")
                        .font(.largeTitle)
                        .padding(.vertical, 50)
                    
                    // Waveform
                    if !bufferEnergy.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 2) {
                                ForEach(Array(bufferEnergy.enumerated()), id: \.offset) { index, energy in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(energy > Float(silenceThreshold) ? Color.green : Color.gray.opacity(0.3))
                                        .frame(width: 4, height: CGFloat(energy) * 60)
                                        .id(index)
                                }
                            }
                        }
                        .scrollPosition(id: $scrollPosition, anchor: .trailing)
                        .frame(height: 80)
                        .background(Rectangle().fill(Color.secondary.opacity(0.3)).shadow(radius: 2))
                        .padding(.top)
                        .onChange(of: bufferEnergy.count) {
                            scrollPosition = bufferEnergy.count - 1
                        }
                    }
                    
                    
                    // Transcribed text
                    ScrollView {
                        Text(transcribedText.isEmpty ? "انقر على الميكروفون لبدء القراءة" : transcribedText)
                            .font(.title)
                            .multilineTextAlignment(.center)
                            .padding()
                            .foregroundColor(transcribedText.isEmpty ? .gray : .primary)
                    }
                    .frame(height: 300)
                    
                    Divider()
                        .shadow(radius: 2)
                    
                    Spacer()
                    
                    // Microphone button
                    Button(action: {
                        if isRecording {
                            stopRecording()
                        } else {
                            startRecording()
                        }
                    }) {
                        ZStack {
                            Circle()
                                .fill(isRecording ? Color.red : Color.blue)
                                .frame(width: 100, height: 100)
                                .shadow(radius: 10)
                            
                            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.bottom, 50)
                    
                    if isRecording {
                        Text(String(format: "%.1f ثانية", bufferSeconds))
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                // Loading view
                VStack(spacing: 20) {
                    ProgressView(value: loadingProgressValue, total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(width: 250)
                    
                    Text(getLoadingText())
                        .font(.title2)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                    
                    Text(String(format: "%.0f%%", loadingProgressValue * 100))
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
        }
        .onAppear {
            loadModelAutomatically()
        }
    }
    
    func getLoadingText() -> String {
        switch modelState {
        case .unloaded:
            return "جاري التحضير"
        case .downloading:
            return "جاري تحميل نموذج الذكاء الاصطناعي"
        case .downloaded:
            return "تم التحميل"
        case .prewarming:
            return "جاري تحسين النموذج"
        case .loading:
            return "جاري التحميل"
        case .loaded:
            return "جاهز"
        case .unloading:
            return "إزالة النموذج"
        case .prewarmed:
            return "تم التحسين"
        }
    }
    
    // MARK: - Model Loading
    
    func loadModelAutomatically() {
        guard modelState == .unloaded else { return }
        Task {
            await loadModel()
        }
    }
    
    func loadModel() async {
        print("Starting model load...")
        
        let config = WhisperKitConfig(
            computeOptions: getComputeOptions(),
            verbose: true,
            logLevel: .debug,
            prewarm: false,
            load: false,
            download: false
        )
        
        do {
            whisperKit = try await WhisperKit(config)
            guard let whisperKit = whisperKit else { return }
            
            var folder: URL?
            
            // Define local model folder path
            if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let modelFolder = documents.appendingPathComponent(modelStorage)
                folder = modelFolder
                
                // Check if model already exists locally
                let modelExists = FileManager.default.fileExists(atPath: modelFolder.path) &&
                FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent("AudioEncoder.mlmodelc").path)
                
                if !modelExists {
                    // Download the Tarteel model
                    await MainActor.run {
                        modelState = .downloading
                    }
                    
                    try await downloadTarteelModel(to: modelFolder)
                } else {
                    print("Model already exists locally")
                }
            }
            
            await MainActor.run {
                loadingProgressValue = specializationProgressRatio
                modelState = .prewarming
            }
            
            if let modelFolder = folder {
                whisperKit.modelFolder = modelFolder
                
                // Prewarm models
                try await whisperKit.prewarmModels()
                
                await MainActor.run {
                    loadingProgressValue = 0.95
                    modelState = .loading
                }
                
                // Load models
                try await whisperKit.loadModels()
                
                await MainActor.run {
                    loadingProgressValue = 1.0
                    modelState = .loaded
                }
            }
        } catch {
            print("Error loading model: \(error)")
            await MainActor.run {
                modelState = .unloaded
            }
        }
    }
    
    // MARK: - Recording
    
    func startRecording() {
        Task {
            guard await AudioProcessor.requestRecordPermission() else {
                print("Microphone access denied")
                return
            }
            
            isRecording = true
            isTranscribing = true
            transcribedText = ""
            bufferEnergy = []
            bufferSeconds = 0
            lastBufferSize = 0
            
            try whisperKit?.audioProcessor.startRecordingLive(inputDeviceID: nil) { _ in
                DispatchQueue.main.async {
                    self.bufferEnergy = self.whisperKit?.audioProcessor.relativeEnergy ?? []
                    self.bufferSeconds = Double(self.whisperKit?.audioProcessor.audioSamples.count ?? 0) / Double(WhisperKit.sampleRate)
                }
            }
            
            // Start real-time transcription loop
            realtimeLoop()
        }
    }
    
    func stopRecording() {
        isRecording = false
        isTranscribing = false
        transcriptionTask?.cancel()
        whisperKit?.audioProcessor.stopRecording()
    }
    
    func realtimeLoop() {
        transcriptionTask = Task {
            while isRecording && isTranscribing {
                do {
                    try await transcribeCurrentBuffer()
                } catch {
                    print("Error: \(error.localizedDescription)")
                    break
                }
            }
        }
    }
    
    func transcribeCurrentBuffer() async throws {
        guard let whisperKit = whisperKit else { return }
        
        let currentBuffer = whisperKit.audioProcessor.audioSamples
        let nextBufferSize = currentBuffer.count - lastBufferSize
        let nextBufferSeconds = Float(nextBufferSize) / Float(WhisperKit.sampleRate)
        
        // Wait for enough audio
        guard nextBufferSeconds > 1.0 else {
            try await Task.sleep(nanoseconds: 100_000_000)
            return
        }
        
        // Check for voice activity
        if useVAD {
            let voiceDetected = AudioProcessor.isVoiceDetected(
                in: whisperKit.audioProcessor.relativeEnergy,
                nextBufferInSeconds: nextBufferSeconds,
                silenceThreshold: Float(silenceThreshold)
            )
            
            guard voiceDetected else {
                try await Task.sleep(nanoseconds: 100_000_000)
                return
            }
        }
        
        lastBufferSize = currentBuffer.count
        
        // Transcribe
        let languageCode = Constants.languages[selectedLanguage, default: "ar"]
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: languageCode,
            temperature: 0,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        
        if let result = try await whisperKit.transcribe(audioArray: Array(currentBuffer), decodeOptions: options).first {
            await MainActor.run {
                transcribedText = result.text
            }
        }
    }
    
    // MARK: - Downloads
    
    func downloadTarteelModel(to destination: URL) async throws {
        print("Downloading Tarteel model to: \(destination.path)")
        
        // Create destination directory if needed
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        
        // Get list of all files from the repo using HuggingFace API
        let apiURL = URL(string: "https://huggingface.co/api/models/\(repoName)/tree/main")!
        let (data, _) = try await URLSession.shared.data(from: apiURL)
        
        struct RepoFile: Codable {
            let type: String
            let path: String
        }
        
        let files = try JSONDecoder().decode([RepoFile].self, from: data)
        
        // Download each file/directory
        var downloadedCount = 0
        let totalFiles = files.count
        
        for file in files {
            await MainActor.run {
                loadingProgressValue = Float(downloadedCount) / Float(totalFiles) * specializationProgressRatio
            }
            
            if file.type == "file" {
                try await downloadFile(repoName: repoName, path: file.path, to: destination)
            } else if file.type == "directory" {
                try await downloadDirectory(repoName: repoName, path: file.path, to: destination)
            }
            
            downloadedCount += 1
        }
        
        print("Model download completed")
    }
    
    func downloadFile(repoName: String, path: String, to destination: URL) async throws {
        let fileURL = URL(string: "https://huggingface.co/\(repoName)/resolve/main/\(path)")!
        let destinationURL = destination.appendingPathComponent(path)
        
        // Create parent directory if needed
        let parentDir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        
        print("Downloading: \(path)")
        let (tempURL, _) = try await URLSession.shared.download(from: fileURL)
        
        // Move to destination
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
    }
    
    func downloadDirectory(repoName: String, path: String, to destination: URL) async throws {
        // Get directory contents
        let apiURL = URL(string: "https://huggingface.co/api/models/\(repoName)/tree/main/\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)")!
        let (data, _) = try await URLSession.shared.data(from: apiURL)
        
        struct RepoFile: Codable {
            let type: String
            let path: String
        }
        
        let files = try JSONDecoder().decode([RepoFile].self, from: data)
        
        // Download each file in directory
        for file in files {
            if file.type == "file" {
                try await downloadFile(repoName: repoName, path: file.path, to: destination)
            } else if file.type == "directory" {
                try await downloadDirectory(repoName: repoName, path: file.path, to: destination)
            }
        }
    }
}

#Preview {
    ContentView()
}

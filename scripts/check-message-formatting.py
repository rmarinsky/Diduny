#!/usr/bin/env python3
"""Run the existing message-formatting cases against ClipboardService using the selected Apple toolchain.

Only unrelated logging/protocol/settings dependencies are stubbed. This does not
replace app-hosted persistence, UI, or end-to-end transcription tests.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'DidunyTests/TranscriptCleanupServiceTests.swift').read_text()
start = source.index('    func chatMessageFormatting() {')
end = source.index('\n    // MARK: - Empty input', start)
cases = source[start:end].replace('    func chatMessageFormatting()', '    static func run()')
cases = cases.replace('#expect(', 'precondition(')
stubs = '''
import Foundation
protocol ClipboardServiceProtocol {}
struct Recording {
    enum RecordingType { case voice, translation, meeting, meetingTranslation, fileTranscription }
}
struct TestLogger {
    func info(_ text: String) {}
    func warning(_ text: String) {}
    func error(_ text: String) {}
}
enum Log { static let app = TestLogger() }
final class SettingsStorage {
    static let shared = SettingsStorage()
    var messageFormattingMode = MessageFormattingMode.normal
}
'''
harness = '@main struct Checks {\n' + cases + '''
    static func main() {
        run()
        SettingsStorage.shared.messageFormattingMode = .chat
        precondition(ClipboardService.preparedMessageText("Так.") == "так")
        precondition(ClipboardService.preparedText("Так.") == "Так.")
        SettingsStorage.shared.messageFormattingMode = .normal
        precondition(ClipboardService.preparedMessageText("Так.") == "Так.")
        print("Message formatting source checks passed (settings dependency stubbed)")
    }
}
'''
swiftc = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
with tempfile.TemporaryDirectory(prefix='diduny-message-check-') as directory:
    work = Path(directory)
    (work / 'Stubs.swift').write_text(stubs)
    (work / 'Checks.swift').write_text(harness)
    subprocess.run([
        swiftc,
        '-sdk', sdk,
        '-module-cache-path', '/tmp/diduny-swift-module-cache',
        str(root / 'Diduny/Core/Services/ClipboardService.swift'),
        str(work / 'Stubs.swift'), str(work / 'Checks.swift'), '-o', str(work / 'checks')
    ], check=True)
    subprocess.run([str(work / 'checks')], check=True)

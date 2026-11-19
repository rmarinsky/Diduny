import Carbon.HIToolbox
import Foundation

struct KeyMapping {
    let keyCode: UInt16
    let needsShift: Bool
    var needsOption: Bool = false
}

struct KeycodeCharacters {
    let normal: Character?
    let shifted: Character?
}

final class CharacterMapper {
    private var sequences: [String: [Character: [KeyMapping]]] = [:]
    private var reverseMaps: [String: [UInt16: KeycodeCharacters]] = [:]
    private var layoutData: [String: CFData] = [:]

    func buildMap(for source: TISInputSource, sourceID: String) {
        guard sequences[sourceID] == nil,
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        let layout = UnsafeRawPointer(CFDataGetBytePtr(data)!).assumingMemoryBound(to: UCKeyboardLayout.self)
        let keyboardType = UInt32(LMGetKbdType())
        var forward: [Character: [KeyMapping]] = [:]
        var reverse: [UInt16: KeycodeCharacters] = [:]
        var deadKeys: [(KeyMapping, UInt32)] = []
        var strokes: [KeyMapping] = []

        // Prefer direct ordinary keys over Option variants or composed sequences.
        for option in [false, true] {
            for shift in [false, true] {
                for code in 0...Constants.maxKeyCode {
                    let stroke = KeyMapping(keyCode: code, needsShift: shift, needsOption: option)
                    strokes.append(stroke)
                    var state: UInt32 = 0
                    guard let text = translate(stroke, layout: layout, keyboardType: keyboardType, state: &state) else { continue }
                    if state != 0 && text.isEmpty { deadKeys.append((stroke, state)) }
                    if let character = singleCharacter(text), forward[character] == nil, state == 0 {
                        forward[character] = [stroke]
                    }
                    if !option {
                        let old = reverse[code]
                        reverse[code] = KeycodeCharacters(normal: shift ? old?.normal : singleCharacter(text),
                                                         shifted: shift ? singleCharacter(text) : old?.shifted)
                    }
                }
            }
        }
        // Recover a composed source character as its physical dead-key sequence.
        // Multi-step IME composition has no Unicode layout table and is not guessed.
        for (deadKey, initialState) in deadKeys {
            for stroke in strokes {
                var state = initialState
                guard let text = translate(stroke, layout: layout, keyboardType: keyboardType, state: &state),
                      let character = singleCharacter(text), forward[character] == nil else { continue }
                forward[character] = [deadKey, stroke]
            }
        }
        sequences[sourceID] = forward
        reverseMaps[sourceID] = reverse
        layoutData[sourceID] = data
    }

    func convert(text: String, fromSourceID: String, toSourceID: String) -> String {
        guard fromSourceID != toSourceID, let source = sequences[fromSourceID], let data = layoutData[toSourceID] else { return text }
        let layout = UnsafeRawPointer(CFDataGetBytePtr(data)!).assumingMemoryBound(to: UCKeyboardLayout.self)
        let keyboardType = UInt32(LMGetKbdType())
        var state: UInt32 = 0
        var result = ""
        for character in text {
            guard let strokes = source[character] else {
                if state != 0 {
                    guard let flushed = translate(KeyMapping(keyCode: 49, needsShift: false), layout: layout,
                                                  keyboardType: keyboardType, state: &state) else { return text }
                    if flushed != " " { result += flushed }
                    state = 0
                }
                result.append(character)
                continue
            }
            for stroke in strokes {
                guard let output = translate(stroke, layout: layout, keyboardType: keyboardType, state: &state) else {
                    // Never return a partly converted string after an OS mapping error.
                    return text
                }
                result += output
            }
        }
        if state != 0 {
            guard let output = translate(KeyMapping(keyCode: 49, needsShift: false), layout: layout,
                                         keyboardType: keyboardType, state: &state) else { return text }
            // UCKeyTranslate can retain opaque nonzero state after committing a
            // character. A plain space means there was no pending accent to flush.
            if output != " " { result += output }
        }
        return result
    }

    func mapping(for character: Character, sourceID: String) -> KeyMapping? {
        sequences[sourceID]?[character]?.first
    }

    func characters(forKeyCode keyCode: UInt16, sourceID: String) -> KeycodeCharacters? {
        reverseMaps[sourceID]?[keyCode]
    }

    func hasMap(for sourceID: String) -> Bool { sequences[sourceID] != nil }

    func invalidateCache() {
        sequences.removeAll()
        reverseMaps.removeAll()
        layoutData.removeAll()
    }

    func invalidateCache(for sourceID: String) {
        sequences.removeValue(forKey: sourceID)
        reverseMaps.removeValue(forKey: sourceID)
        layoutData.removeValue(forKey: sourceID)
    }

    private func singleCharacter(_ text: String) -> Character? {
        guard text.count == 1, let character = text.first,
              !character.isNewline, !character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return character
    }

    private func translate(_ stroke: KeyMapping, layout: UnsafePointer<UCKeyboardLayout>,
                           keyboardType: UInt32, state: inout UInt32) -> String? {
        var modifiers: UInt32 = stroke.needsShift ? UInt32(shiftKey) : 0
        if stroke.needsOption { modifiers |= UInt32(optionKey) }
        var characters = [UniChar](repeating: 0, count: 255)
        var length = 0
        let status = UCKeyTranslate(layout, stroke.keyCode, UInt16(kUCKeyActionDown),
                                    (modifiers >> 8) & 0xFF, keyboardType, 0, &state,
                                    characters.count, &length, &characters)
        guard status == noErr else { return nil }
        return String(decoding: characters.prefix(length), as: UTF16.self)
    }
}

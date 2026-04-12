import Foundation

/// Imports cues from a QLab 5 workspace file (.qlab5).
/// Uses python3's plistlib for fast, reliable NSKeyedArchiver parsing.
/// Recursively walks group cues to capture all nested entries.
struct QLabImporter {

    struct ImportedCue {
        let name: String
        let filePath: String
        let autoFollow: Bool
    }

    static func importCues(from url: URL) throws -> [ImportedCue] {
        let json = try runPythonExtractor(path: url.path)
        let cues = try JSONDecoder().decode([PyCue].self, from: json)
        guard !cues.isEmpty else { throw ImportError.noCuesFound }
        return cues.map {
            ImportedCue(name: $0.name, filePath: $0.filePath, autoFollow: $0.autoFollow)
        }
    }

    // MARK: - Python extraction

    private static func runPythonExtractor(path: String) throws -> Data {
        let script = """
        import plistlib, json, sys, os

        def resolve(x, objs):
            if isinstance(x, plistlib.UID):
                idx = int(x)
                return objs[idx] if idx < len(objs) else None
            return x

        def decode_nsdict(obj, objs):
            if isinstance(obj, dict) and 'NS.keys' in obj:
                keys = [resolve(k, objs) for k in obj['NS.keys']]
                vals = [resolve(v, objs) for v in obj['NS.objects']]
                return dict(zip(keys, vals))
            return obj

        def decode_nsarray(obj, objs):
            if isinstance(obj, dict) and 'NS.objects' in obj and 'NS.keys' not in obj:
                return [resolve(v, objs) for v in obj['NS.objects']]
            return None

        def extract_cues(cue_dict, objs):
            results = []
            name = cue_dict.get('name', '')
            if isinstance(name, plistlib.UID):
                name = resolve(name, objs)
            if not isinstance(name, str):
                name = ''

            # Get file target
            ft_raw = cue_dict.get('fileTarget', None)
            if isinstance(ft_raw, plistlib.UID):
                ft_raw = resolve(ft_raw, objs)
            filepath = None
            if isinstance(ft_raw, dict):
                ft = decode_nsdict(ft_raw, objs) if 'NS.keys' in ft_raw else ft_raw
                lkp = ft.get('lastKnownPath', None)
                if isinstance(lkp, plistlib.UID):
                    lkp = resolve(lkp, objs)
                if isinstance(lkp, str) and lkp:
                    filepath = lkp

            cont = cue_dict.get('continueMode', 0)
            if isinstance(cont, plistlib.UID):
                cont = resolve(cont, objs)
            if not isinstance(cont, (int, float)):
                cont = 0

            # If this cue has a file, add it
            if filepath:
                # Use filename as fallback if name is empty
                display_name = name if name else os.path.splitext(os.path.basename(filepath))[0]
                results.append({
                    'name': display_name,
                    'filePath': filepath,
                    'autoFollow': int(cont) == 1
                })

            # Recurse into sub-cues (group cues)
            sub_raw = cue_dict.get('cues', None)
            if isinstance(sub_raw, plistlib.UID):
                sub_raw = resolve(sub_raw, objs)
            if isinstance(sub_raw, dict):
                arr = decode_nsarray(sub_raw, objs)
                if arr:
                    for sub in arr:
                        if isinstance(sub, plistlib.UID):
                            sub = resolve(sub, objs)
                        if isinstance(sub, dict):
                            sub_d = decode_nsdict(sub, objs) if 'NS.keys' in sub else sub
                            results.extend(extract_cues(sub_d, objs))

            return results

        with open(sys.argv[1], 'rb') as f:
            data = plistlib.load(f)
        objects = data['$objects']
        root = decode_nsdict(resolve(data['$top']['root'], objects), objects)
        cl_wrapper = decode_nsdict(root['cueLists'], objects)
        inner = plistlib.loads(cl_wrapper['NS.data'])
        iobj = inner['$objects']

        # Start from the inner root (which is a cue list cue)
        inner_root = decode_nsdict(resolve(inner['$top']['root'], iobj), iobj)
        cues = extract_cues(inner_root, iobj)
        json.dump(cues, sys.stdout)
        """

        let pythonCandidates = [
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3",
        ]
        guard let pythonPath = pythonCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw ImportError.pythonFailed("python3 not found")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-c", script, path]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0, !outData.isEmpty else {
            let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ImportError.pythonFailed(errStr)
        }

        return outData
    }

    private struct PyCue: Decodable {
        let name: String
        let filePath: String
        let autoFollow: Bool
    }

    enum ImportError: LocalizedError {
        case noCuesFound
        case pythonFailed(String)

        var errorDescription: String? {
            switch self {
            case .noCuesFound: return "No file-based cues found to import."
            case .pythonFailed(let msg): return "QLab import failed: \(msg)"
            }
        }
    }
}

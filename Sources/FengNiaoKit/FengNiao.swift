//
//  FengNiao.swift
//  FengNiao
//
//  Created by WANG WEI on 2017/3/7.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

import Foundation
import PathKit
import Rainbow

enum FileType: String, Codable {
    case swift
    case objc
    case xib
    case plist
    case pbxproj
    
    init?(ext: String) {
        switch ext {
        case "swift": self = .swift
        case "h", "m", "mm": self = .objc
        case "xib", "storyboard": self = .xib
        case "plist": self = .plist
        case "pbxproj": self = .pbxproj
        default: return nil
        }
    }
    
    func searchRules(extensions: [String], patterns: [String]? = nil) -> [FileSearchRule] {
        switch self {
        case .swift:
            if let patterns = patterns {
                return [SwiftImageSearchRule(extensions: extensions, patterns: patterns)]
            } else {
                return [SwiftImageSearchRule(extensions: extensions)]
            }
        case .objc:
            if let patterns = patterns {
                return [ObjCImageSearchRule(extensions: extensions, patterns: patterns)]
            } else {
                return [ObjCImageSearchRule(extensions: extensions)]
            }
        case .xib:
            return [XibImageSearchRule()]
        case .plist:
            return [PlistImageSearchRule(extensions: extensions)]
        case .pbxproj:
            return [PbxprojImageSearchRule(extensions: extensions)]
        }
    }
}

extension FileType {
    var isCustomizable: Bool {
        switch self {
        case .objc, .swift:
            return true
        default:
            return false
        }
    }
}

public struct FileInfo {
    public let path: Path
    public let size: Int
    public let fileName: String
    
    public init(path: String) {
        self.path = Path(path)
        self.size = self.path.size
        self.fileName = self.path.lastComponent
    }
    
    public var readableSize: String {
        return size.fn_readableSize
    }
}

extension Path {
    var size: Int {
        if isDirectory {
            let childrenPaths = try? children()
            return (childrenPaths ?? []).reduce(0) { $0 + $1.size }
        } else {
            // Skip hidden files
            if lastComponent.hasPrefix(".") { return 0 }
            let attr = try? FileManager.default.attributesOfItem(atPath: absolute().string)
            if let num = attr?[.size] as? NSNumber {
                return num.intValue
            } else {
                return 0
            }
        }
    }
}

public enum FengNiaoError: Error {
    case noResourceExtension
    case noFileExtension
    case configFileNotFound
}

public struct FengNiao {

    let projectPath: Path
    let excludedPaths: [Path]
    let resourceExtensions: [String]
    let searchInFileExtensions: [String]
    let searchRulesConfigPath: Path?
    
    let regularDirExtensions = ["imageset", "launchimage", "appiconset", "stickersiconset", "complicationset", "bundle"]
    var nonDirExtensions: [String] {
        return resourceExtensions.filter { !regularDirExtensions.contains($0) }
    }
    private let configLoader: SearchRulesConfigLoaderProtocol?
    
    public init(projectPath: String,
                excludedPaths: [String],
                resourceExtensions: [String],
                searchInFileExtensions: [String],
                searchRulesConfigPath: String? = nil) {
        let path = Path(projectPath).absolute()
        self.projectPath = path
        self.excludedPaths = excludedPaths.map { path + Path($0) }
        self.resourceExtensions = resourceExtensions
        self.searchInFileExtensions = searchInFileExtensions
        if let configPathString = searchRulesConfigPath {
            let configPath = Path(configPathString).absolute()
            self.searchRulesConfigPath = configPath
            self.configLoader = SearchRulesConfigLoader(path: configPath)
        } else {
            self.searchRulesConfigPath = nil
            self.configLoader = nil
        }
    }
    
    public func unusedFiles() throws -> [FileInfo] {
        guard !resourceExtensions.isEmpty else {
            throw FengNiaoError.noResourceExtension
        }
        guard !searchInFileExtensions.isEmpty else {
            throw FengNiaoError.noFileExtension
        }

        let allResources = allResourceFiles()
        let usedNames = try allUsedStringNames()
        
        return FengNiao.filterUnused(from: allResources, used: usedNames).map( FileInfo.init )
    }
    
    // Return a failed list of deleting
    static public func delete(_ unusedFiles: [FileInfo]) -> (deleted: [FileInfo], failed: [(FileInfo, Error)]) {
        var deleted = [FileInfo]()
        var failed = [(FileInfo, Error)]()
        for file in unusedFiles {
            do {
                try file.path.delete()
                deleted.append(file)
            } catch {
                failed.append((file, error))
            }
        }
        return (deleted, failed)
    }
    
    // delete the project.pbxproj image reference
    static public func deleteReference(projectFilePath: Path, deletedFiles: [FileInfo]) {
        if let content: String = try? projectFilePath.read() {
            let lines = content.components(separatedBy: .newlines)
            var results:[String] = []
            for line in lines {
                var containImage = true
                outerLoop: for file in deletedFiles {
                    if line.contains(file.fileName) {
                        containImage = false
                        continue outerLoop
                    }
                }
                if containImage {
                    results.append(line)
                }
            }
            
            let resultString = results.joined(separator: "\n")
            
            do {
                try projectFilePath.write(resultString)
            } catch {
                print(error)
            }
            
        }
        
    }
    
    func allResourceFiles() -> [String: Set<String>] {
        let find = ExtensionFindProcess(path: projectPath, extensions: resourceExtensions, excluded: excludedPaths)
        guard let result = find?.execute() else {
            print("Resource finding failed.".red)
            return [:]
        }
        
        var files = [String: Set<String>]()
        fileLoop: for file in result {
            
            // Skip resources in a bundle
            let dirPaths = regularDirExtensions.map { ".\($0)/" }
            for dir in dirPaths where file.contains(dir) {
                continue fileLoop
            }
            
            // Skip the folders which suffix with a non-folder extension.
            // eg: We need to skip a folder with such name: /myfolder.png/ (although we should blame the one who named it)
            let filePath = Path(file)
            if let ext = filePath.extension, filePath.isDirectory && nonDirExtensions.contains(ext) {
                continue
            }
            
            let key = file.plainFileName(extensions: resourceExtensions)
            if let existing = files[key] {
                files[key] = existing.union([file])
            } else {
                files[key] = [file]
            }
        }
        return files
    }
    
    func allUsedStringNames() throws -> Set<String> {
        do {
            let searchRulesConfig = try configLoader?.start()
            return usedStringNames(at: projectPath, searchRulesConfig: searchRulesConfig)
        } catch {
            if case SearchRulesConfigLoaderError.fileNotFound = error {
                throw FengNiaoError.configFileNotFound
            } else {
                throw error
            }
        }
    }
    
    func usedStringNames(at path: Path, searchRulesConfig: SearchRuleConfig? = nil) -> Set<String> {
        guard let subPaths = try? path.children() else {
            print("Failed to get contents in path: \(path)".red)
            return []
        }
        
        var result = [String]()
        for subPath in subPaths {
            if subPath.lastComponent.hasPrefix(".") {
                continue
            }
            
            if excludedPaths.contains(subPath) {
                continue
            }
            
            if subPath.isDirectory {
                result.append(contentsOf: usedStringNames(at: subPath, searchRulesConfig: searchRulesConfig))
            } else {
                let fileExt = subPath.extension ?? ""
                guard searchInFileExtensions.contains(fileExt) else {
                    continue
                }
                
                let fileType = FileType(ext: fileExt)
                var searchRules: [FileSearchRule] {
                    guard let fileType = fileType else {
                        return [PlainImageSearchRule(extensions: resourceExtensions)]
                    }
                    
                    let patterns = searchRulesConfig?.getRule(for: fileType)?.patterns
                    return fileType.searchRules(extensions: resourceExtensions,
                                                patterns: patterns)

                }
                
                let content = (try? subPath.read()) ?? ""
                result.append(contentsOf: searchRules.flatMap {
                    $0.search(in: content).map { name in
                        let p = Path(name)
                        guard let ext = p.extension else { return name }
                        return resourceExtensions.contains(ext) ? p.lastComponentWithoutExtension : name
                    }
                })
            }
        }
        
        return Set(result)
    }
    
    static func filterUnused(from all: [String: Set<String>], used: Set<String>) -> Set<String> {
        let unusedPairs = all.filter { key, _ in
            return !used.contains(key) &&
                   !used.contains { $0.similarPatternWithNumberIndex(other: key) }
        }
        return Set( unusedPairs.flatMap { $0.value } )
    }
}

let digitalRex = try! NSRegularExpression(pattern: "(\\d+)", options: .caseInsensitive)
extension String {
    
    func similarPatternWithNumberIndex(other: String) -> Bool {
        // self -> pattern "image%02d"
        // other -> name "image01"
        let matches = digitalRex.matches(in: other, options: [], range: other.fullRange)
        // No digital found in resource key.
        guard matches.count >= 1 else { return false }
        let lastMatch = matches.last!
        let digitalRange = lastMatch.range(at: 1)
        
        var prefix: String?
        var suffix: String?

        let digitalLocation = digitalRange.location
        if digitalLocation != 0 {
            let index = other.index(other.startIndex, offsetBy: digitalLocation)
            prefix = String(other[..<index])
        }
        
        let digitalMaxRange = NSMaxRange(digitalRange)
        if digitalMaxRange < other.utf16.count {
            let index = other.index(other.startIndex, offsetBy: digitalMaxRange)
            suffix = String(other[index...])
        }
        
        switch (prefix, suffix) {
        case (nil, nil):
            return false // only digital
        case (let p?, let s?):
            return hasPrefix(p) && hasSuffix(s)
        case (let p?, nil):
            return hasPrefix(p)
        case (nil, let s?):
            return hasSuffix(s)
        }
    }
}

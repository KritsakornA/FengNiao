//
//  SearchRulesConfigLoader.swift
//  
//
//  Created by Kritsakorn Akwannang on 26/12/2566 BE.
//

import Foundation
import PathKit

enum FiengNiaoFileError: Error {
    case fileNotExist
}

protocol SearchRulesConfigLoaderProtocol {
    var path: Path { get }
    
    func start() throws -> SearchRuleConfig
}

struct SearchRulesConfigLoader: SearchRulesConfigLoaderProtocol {
    
    let path: Path
    private let fileManager = FileManager.default
    
    init(path: Path) {
        self.path = path
    }
    
    func start() throws -> SearchRuleConfig {
        return try loadSearchRulesConfig(at: path)
    }
    
    private func loadSearchRulesConfig(at path: Path) throws -> SearchRuleConfig {
        guard let data = fileManager.contents(atPath: path.absolute().string) else {
            throw FiengNiaoFileError.fileNotExist
        }
        
        do {
            let template = try JSONDecoder().decode(SearchRuleConfig.self, from: data)
            return template
        } catch {
            throw error
        }
    }
}

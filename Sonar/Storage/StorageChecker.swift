//
//  StorageChecker.swift
//  Sonar
//
//  Created by NHSX on 04/05/2020.
//  Copyright © 2020 NHSX. All rights reserved.
//

import Foundation

enum StorageState {
    case notInitialized
    case keyChainAndUserDefaultsOutOfSync
    case inSync
}

protocol StorageChecking {
    var state: StorageState { get }
    func markAsSynced()
}

class StorageChecker: StorageChecking {
        
    private let service: String
    
    init(service: String) {
        self.service = service
    }
    
    var state: StorageState {
        let valueInKeychain = readFromKeychain()
        let valueInDefaults = readFromUserDefaults()
        switch (valueInKeychain, valueInDefaults) {
        case (nil, nil):
            return .notInitialized
        case (let lhs, let rhs) where lhs == rhs:
            return .inSync
        default:
            return .keyChainAndUserDefaultsOutOfSync
        }
    }
    
    func markAsSynced() {
        let token = UUID().data
        writeToKeychain(with: token)
        writeToUserDefaults(with: token)
    }

    //MARK: - Private
    
    private func writeToUserDefaults(with token: Data) {
        UserDefaults.standard.set(token, forKey: service)
    }
    
    private func writeToKeychain(with token: Data) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: token,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }
    
    private func readFromKeychain() -> UUID? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        
        let data = result as! CFData
        return UUID(data: data as Data)
    }
    
    private func readFromUserDefaults() -> UUID? {
        guard let data = UserDefaults.standard.object(forKey: service) as? Data else { return nil }
        return UUID(data: data)
    }
    
}

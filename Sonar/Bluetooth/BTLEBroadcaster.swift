//
//  BTLEBroadcaster.swift
//  Sonar
//
//  Created by NHSX on 11/03/2020.
//  Copyright © 2020 NHSX. All rights reserved.
//

import Foundation
import CoreBluetooth
import UIKit
import Logging

protocol BTLEBroadcaster {
    func sendKeepalive(value: Data)
    func updateIdentity()

    func isHealthy() -> Bool
}

class ConcreteBTLEBroadcaster: NSObject, BTLEBroadcaster, CBPeripheralManagerDelegate {

    let advertismentDataLocalName = "Sonar"

    enum UnsentCharacteristicValue {
        case keepalive(value: Data)
        case identity(value: Data)
    }
    var unsentCharacteristicValue: UnsentCharacteristicValue?
    var keepaliveCharacteristic: CBMutableCharacteristic?
    var identityCharacteristic: CBMutableCharacteristic?
    
    var peripheral: CBPeripheralManager?
    
    let idGenerator: BroadcastPayloadGenerator
    
    init(idGenerator: BroadcastPayloadGenerator) {
        self.idGenerator = idGenerator
    }

    private func start() {
        guard let peripheral = peripheral else {
            assertionFailure("peripheral shouldn't be nil")
            return
        }
        guard peripheral.isAdvertising == false else {
            logger.error("peripheral manager already advertising, won't start again")
            return
        }

        let service = CBMutableService(type: Environment.sonarServiceUUID, primary: true)

        identityCharacteristic = CBMutableCharacteristic(
            type: Environment.sonarIdCharacteristicUUID,
            properties: CBCharacteristicProperties([.read, .notify]),
            value: nil,
            permissions: .readable)
        
        keepaliveCharacteristic = CBMutableCharacteristic(
            type: Environment.keepaliveCharacteristicUUID,
            properties: CBCharacteristicProperties([.notify]),
            value: nil,
            permissions: .readable)

        service.characteristics = [identityCharacteristic!, keepaliveCharacteristic!]
        peripheral.add(service)
    }

    func sendKeepalive(value: Data) {
        guard let peripheral = self.peripheral else {
            logger.info("peripheral shouldn't be nil")
            return
        }
        guard let keepaliveCharacteristic = self.keepaliveCharacteristic else {
            logger.info("keepaliveCharacteristic shouldn't be nil")
            return
        }
        
        self.unsentCharacteristicValue = .keepalive(value: value)
        let success = peripheral.updateValue(value, for: keepaliveCharacteristic, onSubscribedCentrals: nil)
        if success {
            logger.info("sent keepalive value: \(value.withUnsafeBytes { $0.load(as: UInt8.self) })")
            self.unsentCharacteristicValue = nil
        }
    }
    
    func updateIdentity() {
        guard let identityCharacteristic = self.identityCharacteristic else {
            // This "shouldn't happen" in normal course of the code, but if you start the
            // app with Bluetooth off and don't turn it on until registration is completed
            // you can get here.
            logger.info("identity characteristic not created yet")
            return
        }
        
        guard let broadcastPayload = idGenerator.broadcastPayload()?.data() else {
            assertionFailure("attempted to update identity without an identity")
            return
        }
        
        guard let peripheral = self.peripheral else {
            assertionFailure("peripheral shouldn't be nil")
            return
        }
        
        self.unsentCharacteristicValue = .identity(value: broadcastPayload)
        let success = peripheral.updateValue(broadcastPayload, for: identityCharacteristic, onSubscribedCentrals: nil)
        if success {
            logger.info("sent identity value \(broadcastPayload)")
            self.unsentCharacteristicValue = nil
        }
    }

    
    // MARK: - CBPeripheralManagerDelegate

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String : Any]) {
        guard let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] else {
            logger.info("no services restored, creating from scratch...")
            return
        }
        for service in services {
            logger.info("restoring service \(service)")
            guard let characteristics = service.characteristics else {
                assertionFailure("service has no characteristics, this shouldn't happen")
                return
            }
            for characteristic in characteristics {
                if characteristic.uuid == Environment.keepaliveCharacteristicUUID {
                    logger.info("    retaining restored keepalive characteristic \(characteristic)")
                    self.keepaliveCharacteristic = (characteristic as! CBMutableCharacteristic)
                } else if characteristic.uuid == Environment.sonarIdCharacteristicUUID {
                    logger.info("    retaining restored identity characteristic \(characteristic)")
                    self.identityCharacteristic = (characteristic as! CBMutableCharacteristic)
                } else {
                    logger.info("    restored characteristic \(characteristic)")
                }
            }
        }
        if let advertismentData = dict[CBPeripheralManagerRestoredStateAdvertisementDataKey] as? [String: Any] {
            logger.info("restored advertisementData \(advertismentData)")
        }
        logger.info("peripheral manager \(peripheral.isAdvertising ? "is" : "is not") advertising")
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        logger.info("state: \(peripheral.state)")
        
        switch peripheral.state {
            
        case .poweredOn:
            self.peripheral = peripheral
            start()
            
        default:
            break
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else {
            logger.info("error: \(error!))")
            return
        }
        
        logger.info("advertising identifier \(idGenerator.broadcastPayload()?.data().base64EncodedString() ??? "nil")")

        // Per #172564329 we don't want to expose this in release builds
        #if DEBUG
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: advertismentDataLocalName,
            CBAdvertisementDataServiceUUIDsKey: [service.uuid]
        ])
        #else
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [service.uuid]
        ])
        #endif
    }
    
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        let characteristic: CBMutableCharacteristic
        let value: Data
        
        switch unsentCharacteristicValue {
        case nil:
            assertionFailure("\(#function) no data to update")
            return
            
        case .identity(let identityValue) where self.identityCharacteristic != nil:
            value = identityValue
            characteristic = self.identityCharacteristic!
            
        case .keepalive(let keepaliveValue) where self.keepaliveCharacteristic != nil:
            value = keepaliveValue
            characteristic = self.keepaliveCharacteristic!
            
        default:
            assertionFailure("shouldn't happen")
            return
        }
        
        let success = peripheral.updateValue(value, for: characteristic, onSubscribedCentrals: nil)
        if success {
            print("\(#function) re-sent value \(value)")
            self.unsentCharacteristicValue = nil
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == Environment.sonarIdCharacteristicUUID else {
            logger.debug("received a read for unexpected characteristic \(request.characteristic.uuid.uuidString)")
            return
        }

        guard let broadcastPayload = idGenerator.broadcastPayload()?.data() else {
            logger.info("responding to read request with empty payload")
            request.value = Data()
            peripheral.respond(to: request, withResult: .success)
            return
        }
        
        logger.info("responding to read request with \(broadcastPayload)")
        request.value = broadcastPayload
        peripheral.respond(to: request, withResult: .success)
    }

    // MARK: - Healthcheck
    func isHealthy() -> Bool {
        guard peripheral != nil else { return false }
        guard identityCharacteristic != nil else { return false }
        guard keepaliveCharacteristic != nil else { return false }

        guard idGenerator.broadcastPayload() != nil else { return false }
        guard peripheral!.isAdvertising else { return false }
        guard peripheral!.state == .poweredOn else { return false }

        return true
    }
}

fileprivate let logger = Logger(label: "BTLE")

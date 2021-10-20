import Foundation
import CoreData
import CoreBluetooth
import SwiftUI

//---------------------------------------------------------------------------------------
// Meshtastic BLE Device Manager
//---------------------------------------------------------------------------------------
class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
	
	private static var documentsFolder: URL {
		do {
			return try FileManager.default.url(for: .documentDirectory,
											   in: .userDomainMask,
											   appropriateFor: nil,
											   create: true)
		} catch {
			fatalError("Can't find documents directory.")
		}
	}
    
    @ObservedObject private var meshData : MeshData
    @ObservedObject private var messageData : MessageData
    
    private var centralManager: CBCentralManager!
    
    @Published var connectedPeripheral: Peripheral!
    @Published var connectedNode: NodeInfoModel!
    @Published var lastConnectedPeripheral: String
    @Published var lastConnectionError: String
    
    @Published var isSwitchedOn = false
    @Published var peripherals = [Peripheral]()
	
	private var meshLoggingEnabled: Bool = true
    
    private var broadcastNodeId: UInt32 = 4294967295

    /* Meshtastic Service Details */
    var TORADIO_characteristic: CBCharacteristic!
    var FROMRADIO_characteristic: CBCharacteristic!
    var FROMNUM_characteristic: CBCharacteristic!
    
    let meshtasticServiceCBUUID = CBUUID(string: "0x6BA1B218-15A8-461F-9FA8-5DCAE273EAFD")
    let TORADIO_UUID = CBUUID(string: "0xF75C76D2-129E-4DAD-A1DD-7866124401E7")
    let FROMRADIO_UUID = CBUUID(string: "0x8BA2BCC2-EE02-4A55-A531-C525C5E454D5")
    let FROMNUM_UUID = CBUUID(string: "0xED9DA18C-A800-4F66-A670-AA7547E34453")
	
	let meshLog = documentsFolder.appendingPathComponent("meshlog.txt")
    
    /* init BLEManager */
    override init() {
        
        self.meshData = MeshData()
        self.messageData = MessageData()
        self.lastConnectedPeripheral = ""
        self.lastConnectionError = ""
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        meshData.load()
        messageData.load()
    }

    // called when bluetooth is enabled/disabled for the app
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
         if central.state == .poweredOn {
             
             isSwitchedOn = true
         }
         else {
             
             isSwitchedOn = false
         }
    }
    
    // Scan for nearby BLE devices using the Meshtastic BLE service ID
    func startScanning() {
        
        if isSwitchedOn {
            
            peripherals.removeAll()
            centralManager.scanForPeripherals(withServices: [meshtasticServiceCBUUID], options: nil)
            print("Scanning Started")
        }
    }
        
    // Stop Scanning For BLE Devices
    func stopScanning() {
        
        if centralManager.isScanning {
            
            self.centralManager.stopScan()
            print("Stopped Scanning")
        }
    }
    
    // Connect to a specific peripheral
    func connectTo(peripheral: CBPeripheral) {
        
        stopScanning()
        if connectedPeripheral != nil && connectedPeripheral.peripheral.state == CBPeripheralState.connected {
            self.disconnectDevice()
        }

        self.centralManager?.connect(peripheral)
		if meshLoggingEnabled { Logger.log("BLE Connecting: \(peripheral.name ?? "Unknown")") }
        print("BLE Connecting: \(peripheral.name ?? "Unknown")")
    }
    
    //  Disconnect Device function
    func disconnectDevice(){
        
        if connectedPeripheral != nil {
            self.centralManager?.cancelPeripheralConnection(connectedPeripheral.peripheral)
        }
    }
    
    // Called each time a peripheral is discovered
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        
        var peripheralName: String = peripheral.name ?? "Unknown"
        
        if let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            peripheralName = name
        }
			
		let newPeripheral = Peripheral(id: peripheral.identifier.uuidString, name: peripheralName, rssi: RSSI.intValue, peripheral: peripheral, myInfo: nil)
		peripherals.append(newPeripheral)
		print("Adding peripheral: \(peripheralName)");
    }
    
    // called when a peripheral is connected
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {

		stopScanning()
        peripheral.delegate = self
        connectedPeripheral = peripherals.filter({ $0.peripheral.identifier == peripheral.identifier }).first
		let deviceName = peripheral.name ?? ""
		
		let peripheralLast4: String = String(deviceName.suffix(4))
		print(peripheralLast4)
		
		connectedNode = meshData.nodes.first(where: { $0.user.id.contains(peripheralLast4) })
        lastConnectedPeripheral = peripheral.identifier.uuidString
        peripheral.discoverServices([meshtasticServiceCBUUID])
		if meshLoggingEnabled { Logger.log("BLE Connected: \(peripheral.name ?? "Unknown")") }
        print("BLE Connected: \(peripheral.name ?? "Unknown")")
		peripherals.removeAll()
    }

    // Disconnect Peripheral Event
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?)
    {
        // Start a Scan so the disconnected peripheral is moved to the peripherals[] if it is awake
        self.startScanning()
        
        if let e = error {
        
            let errorCode = (e as NSError).code
            
            if errorCode == 6 { // The connection has timed out unexpectedly.
                
                // Happens when device is manually reset / powered off
                // 2 second delay for device to power back on
                let _ = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { (timer) in
                    
					//self.connectedPeripheral = nil
					self.connectedNode = nil
                    self.connectTo(peripheral: peripheral)
                }
            }
            else if errorCode == 7 { // The specified device has disconnected from us.
             
                // Seems to be what is received when a tbeam sleeps, immediately recconnecting does not work.
                // Check if the last connected peripheral is still visible and then reconnect
				connectedPeripheral = nil
				connectedNode = nil

            }
            else if errorCode == 14 { // Peer error that may require forgetting device in settings
                
                // Forgetting and reconnecting seems to be necessary so we need to show the user an error telling them to do that
				connectedPeripheral = nil
				connectedNode = nil
                lastConnectionError = (e as NSError).description
            }
			print("Central disconnected because \(e)")
			if meshLoggingEnabled { Logger.log("BLE Disconnected: \(peripheral.name ?? "Unknown") Error Code: \(errorCode) Error: \(e.localizedDescription)") }
        } else {
            
            // Disconnected without error which indicates user intent to disconnect
			connectedPeripheral = nil
			connectedNode = nil
			if meshLoggingEnabled { Logger.log("BLE Disconnected: \(peripheral.name ?? "Unknown"): User Initiated Disconnect" ) }
            print("Central disconnected! (no error)")
        }

        print("Peripheral disconnected: " + peripheral.name!)
    }
    
    // Discover Services Event
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        
        if let e = error {
            
            print("Discover Services error \(e)")
        }
        
        guard let services = peripheral.services else { return }
                
        for service in services
        {
            
            
            if (service.uuid == meshtasticServiceCBUUID)
            {
                print("Meshtastic service discovered OK")
				if meshLoggingEnabled { Logger.log("BLE Service for Meshtastic discovered by \(peripheral.name ?? "Unknown")") }
                //peripheral.discoverCharacteristics(nil, for: service)
                peripheral.discoverCharacteristics([TORADIO_UUID, FROMRADIO_UUID, FROMNUM_UUID], for: service)
            }
        }
    }
    
    // Discover Characteristics Event
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?)
    {
        if let e = error {
            
            print("Discover Characteristics error \(e)")
			if meshLoggingEnabled { Logger.log("BLE didDiscoverCharacteristicsFor error by \(peripheral.name ?? "Unknown") \(e)") }
        }
        
        guard let characteristics = service.characteristics else { return }

        for characteristic in characteristics {
        
        switch characteristic.uuid
        {
            case TORADIO_UUID:
                print("TORADIO characteristic OK")
				if meshLoggingEnabled { Logger.log("BLE did discover TORADIO characteristic for Meshtastic by \(peripheral.name ?? "Unknown")") }
                TORADIO_characteristic = characteristic
                var toRadio: ToRadio = ToRadio()
                toRadio.wantConfigID = 32168
                let binaryData: Data = try! toRadio.serializedData()
                peripheral.writeValue(binaryData, for: characteristic, type: .withResponse)
                break
            
            case FROMRADIO_UUID:
                print("FROMRADIO characteristic OK")
				if meshLoggingEnabled { Logger.log("BLE did discover FROMRADIO characteristic for Meshtastic by \(peripheral.name ?? "Unknown")") }
                FROMRADIO_characteristic = characteristic
                peripheral.readValue(for: FROMRADIO_characteristic)
                break
            
            case FROMNUM_UUID:
                print("FROMNUM (Notify) characteristic OK")
				if meshLoggingEnabled { Logger.log("BLE did discover FROMNUM (Notify) characteristic for Meshtastic by \(peripheral.name ?? "Unknown")") }
                FROMNUM_characteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                break
            
            default:
                break
        }
        
      }
    }
    
    // Data Read / Update Characteristic Event
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?)
    {
        if let e = error {
            
            print("didUpdateValueFor Characteristic error \(e)")
			if meshLoggingEnabled { Logger.log("BLE didUpdateValueFor characteristic error by \(peripheral.name ?? "Unknown") \(e)") }
        }
        
        switch characteristic.uuid
        {
            case FROMNUM_UUID:
                peripheral.readValue(for: FROMNUM_characteristic)
                //let byteArrayFromData: [UInt8] = [UInt8](characteristic.value!)
                //let stringFromByteArray = String(data: Data(_: byteArrayFromData), encoding: .utf8)
                //print("string array data \(stringFromByteArray!)")
                //print(characteristic.value?. ?? "no value")
    
                
            case FROMRADIO_UUID:
                if (characteristic.value == nil || characteristic.value!.isEmpty)
                {
                    return
                }
                //print(characteristic.value ?? "no value")
                //print(characteristic.value?.hexDescription ?? "no value")
                var decodedInfo = FromRadio()
                
                decodedInfo = try! FromRadio(serializedData: characteristic.value!)
                //print("Print DecodedInfo")
                //print(decodedInfo)
                
                if decodedInfo.myInfo.myNodeNum != 0
                {

                    // Create a MyInfoModel
                    let myInfoModel = MyInfoModel(
                        myNodeNum: decodedInfo.myInfo.myNodeNum,
                        hasGps: decodedInfo.myInfo.hasGps_p,
                        numBands: decodedInfo.myInfo.numBands,
                        maxChannels: decodedInfo.myInfo.maxChannels,
                        firmwareVersion: decodedInfo.myInfo.firmwareVersion,
                        messageTimeoutMsec: decodedInfo.myInfo.messageTimeoutMsec,
                        minAppVersion: decodedInfo.myInfo.minAppVersion)
                    
                    // Save it to the connected nodeInfo
                    if connectedPeripheral != nil {
                        connectedPeripheral.myInfo = myInfoModel
                        // Save it to the connected node
                        connectedNode = meshData.nodes.first(where: {$0.num == myInfoModel.myNodeNum})
                        
                    }
                    // Since the data is from the device itself we save all myInfo objects since they are always the most up to date
                    if connectedNode != nil {
                        connectedNode.myInfo = myInfoModel
                        connectedNode.update(from: connectedNode.data)
                        let nodeIndex = meshData.nodes.firstIndex(where: { $0.id == decodedInfo.myInfo.myNodeNum })
                        meshData.nodes.remove(at: nodeIndex!)
                        meshData.nodes.append(connectedNode)
						meshData.save()
                        print("Saved a myInfo for \(decodedInfo.myInfo.myNodeNum)")
						if meshLoggingEnabled { Logger.log("BLE FROMRADIO received and myInfo saved for \(peripheral.name ?? "Unknown")") }
                    }
                }
                
                if decodedInfo.nodeInfo.num != 0 {
                    
                    print("Save a nodeInfo")

                    if meshData.nodes.contains(where: {$0.id == decodedInfo.nodeInfo.num}) {
                        
                        // Found a matching node lets update it
                        let nodeMatch = meshData.nodes.first(where: { $0.id == decodedInfo.nodeInfo.num })
                        if connectedPeripheral != nil && connectedPeripheral.myInfo?.myNodeNum == nodeMatch?.num {
                            connectedNode = nodeMatch
                        }
                        
                        if nodeMatch?.lastHeard ?? 0 < decodedInfo.nodeInfo.lastHeard && nodeMatch?.user != nil && nodeMatch?.user.longName.count ?? 0 > 0 {
                            // The data coming from the device is newer
                            
                            let nodeIndex = meshData.nodes.firstIndex(where: { $0.id == decodedInfo.nodeInfo.num })
                            meshData.nodes.remove(at: nodeIndex!)
                            meshData.save()
                        }
                        else {
                            
                            // Data is older than what the app already has
                            return
                        }
                    }
                    // Set the connected node if the nodeInfo is for the connected node.
                    if connectedPeripheral != nil && connectedPeripheral.myInfo?.myNodeNum == decodedInfo.nodeInfo.num {
                        
                        let nodeMatch = meshData.nodes.first(where: { $0.id == decodedInfo.nodeInfo.num })
                        if nodeMatch != nil {
                            connectedNode = nodeMatch
                        }
                    }
                    if decodedInfo.nodeInfo.hasUser {
                    
                        meshData.nodes.append(
                            NodeInfoModel(
                                num: decodedInfo.nodeInfo.num,
                                user: NodeInfoModel.User(
                                    id: decodedInfo.nodeInfo.user.id,
                                    longName: decodedInfo.nodeInfo.user.longName,
                                    shortName: decodedInfo.nodeInfo.user.shortName,
                                    //macaddr: decodedInfo.nodeInfo.user.macaddr,
                                    hwModel: String(describing: decodedInfo.nodeInfo.user.hwModel)
                                        .uppercased()),
                                
                                position: NodeInfoModel.Position(
                                    latitudeI: decodedInfo.nodeInfo.position.latitudeI,
                                    longitudeI: decodedInfo.nodeInfo.position.longitudeI,
                                    altitude: decodedInfo.nodeInfo.position.altitude,
                                    batteryLevel: decodedInfo.nodeInfo.position.batteryLevel,
                                    time: decodedInfo.nodeInfo.position.time),
                                
                                lastHeard: decodedInfo.nodeInfo.lastHeard,
                                snr: decodedInfo.nodeInfo.snr)
                        )
                        meshData.save()
						if meshLoggingEnabled { Logger.log("BLE FROMRADIO received and nodeInfo saved for \(decodedInfo.nodeInfo.user.longName)") }
                    }
            }
            // Handle assorted app packets
            if decodedInfo.packet.id  != 0 {
                
                print("Handle a Packet")
                do {
                    // Text Message App - Primary Broadcast Channel
                    if decodedInfo.packet.decoded.portnum == PortNum.textMessageApp {
                             
                        if let messageText = String(bytes: decodedInfo.packet.decoded.payload, encoding: .utf8) {
                            
                            print("Message Text: \(messageText)")
							if meshLoggingEnabled { Logger.log("BLE FROMRADIO received for text message app \(messageText)") }

                            let fromUser = meshData.nodes.first(where: { $0.id == decodedInfo.packet.from })

                            var toUserLongName: String = "Broadcast"
                            var toUserShortName: String = "BC"

                            if decodedInfo.packet.to != broadcastNodeId {

                            let toUser = meshData.nodes.first(where: { $0.id == decodedInfo.packet.from })
                            toUserLongName = toUser?.user.longName ?? "Unknown"
                            toUserShortName = toUser?.user.shortName ?? "???"
                        }
                            
                        // Add the received message to the local messages list / file and save
                        messageData.messages.append(
                            MessageModel(
                                messageId: decodedInfo.packet.id,
                                messageTimeStamp: decodedInfo.packet.rxTime,
                                fromUserId: decodedInfo.packet.from,
                                toUserId: decodedInfo.packet.to,
                                fromUserLongName: fromUser?.user.longName ?? "Unknown",
                                toUserLongName: toUserLongName,
                                fromUserShortName: fromUser?.user.shortName ?? "???",
                                toUserShortName: toUserShortName,
                                receivedACK: decodedInfo.packet.decoded.wantResponse,
                                messagePayload: messageText,
                                direction: "IN")
                        )
                        messageData.save()
                            
                        // Create an iOS Notification for the received message and schedule it immediately
                        let manager = LocalNotificationManager()
                            
                        manager.notifications = [
                            Notification(
                                id: ("notification.id.\(decodedInfo.packet.id)"),
                                title: "\(fromUser?.user.longName ?? "Unknown")",
                                subtitle: "AKA \(fromUser?.user.shortName ?? "???")",
                                content: messageText)
                        ]
                        manager.schedule()
						if meshLoggingEnabled { Logger.log("iOS Notification Scheduled for text message from \(fromUser?.user.longName ?? "Unknown") \(messageText)") }
                    }
                }
                else if  decodedInfo.packet.decoded.portnum == PortNum.nodeinfoApp {

                    var updatedNode = meshData.nodes.first(where: {$0.id == decodedInfo.packet.from })
					if updatedNode != nil {
						if meshLoggingEnabled { Logger.log("BLE FROMRADIO received for node info app for \(updatedNode!.user.longName)") }
					}

                    if updatedNode != nil {
                        updatedNode!.snr = decodedInfo.packet.rxSnr
                        updatedNode!.lastHeard = decodedInfo.packet.rxTime
                        //updatedNode!.update(from: updatedNode!.data)
                        let nodeIndex = meshData.nodes.firstIndex(where: { $0.id == decodedInfo.packet.from })
                        meshData.nodes.remove(at: nodeIndex!)
                        meshData.nodes.append(updatedNode!)
                        meshData.save()
						if meshLoggingEnabled { Logger.log("Updated NodeInfo SNR and Time from Node Info App Packet For: \(updatedNode!.user.longName)") }
                        print("Updated NodeInfo SNR and Time from Packet For: \(updatedNode!.user.longName)")
                    }
                }
                else if  decodedInfo.packet.decoded.portnum == PortNum.positionApp {

                    var updatedNode = meshData.nodes.first(where: {$0.id == decodedInfo.packet.from })

                    if updatedNode != nil {
                        updatedNode!.snr = decodedInfo.packet.rxSnr
                        updatedNode!.lastHeard = decodedInfo.packet.rxTime
                        //updatedNode!.update(from: updatedNode!.data)
                        let nodeIndex = meshData.nodes.firstIndex(where: { $0.id == decodedInfo.packet.from })
                        meshData.nodes.remove(at: nodeIndex!)
                        meshData.nodes.append(updatedNode!)
                        meshData.save()

						if meshLoggingEnabled { Logger.log("Updated NodeInfo SNR and Time from Position App Packet For: \(updatedNode!.user.longName)") }
                        print("Updated Position SNR and Time from Packet For: \(updatedNode!.user.longName)")
                    }
					print("Postion Payload")
					print(try decodedInfo.packet.jsonString())
                }
				else if  decodedInfo.packet.decoded.portnum == PortNum.adminApp {
					 
					 if meshLoggingEnabled { Logger.log("BLE FROMRADIO received for Admin App UNHANDLED \(try decodedInfo.packet.jsonString())") }
					 print("Admin App Packet")
					 print(try decodedInfo.packet.jsonString())
				 }
				 else if  decodedInfo.packet.decoded.portnum == PortNum.routingApp {
					 
					 if meshLoggingEnabled { Logger.log("BLE FROMRADIO received for Routing App UNHANDLED \(try decodedInfo.packet.jsonString())") }
					 print("Routing App Packet")
					 print(try decodedInfo.packet.jsonString())
				 }
				 else
				 {
					 if meshLoggingEnabled { Logger.log("BLE FROMRADIO received for Other App UNHANDLED \(try decodedInfo.packet.jsonString())") }
					 print("Other App Packet")
					 print(try decodedInfo.packet.jsonString())
				 }
                        
                    } catch {
						if meshLoggingEnabled { Logger.log("Fatal Error: Failed to decode json") }
                        fatalError("Failed to decode json")
                    }
                }
                
                if decodedInfo.configCompleteID != 0 {
					if meshLoggingEnabled { Logger.log("Config Complete: \(decodedInfo.configCompleteID)") }
					print("BLE Config Complete Packet Id: \(decodedInfo.configCompleteID)")

                }
                
            default:
			
				if meshLoggingEnabled { Logger.log("Unhandled Characteristic UUID: \(characteristic.uuid)") }
                print("Unhandled Characteristic UUID: \(characteristic.uuid)")
        }
        peripheral.readValue(for: FROMRADIO_characteristic)
    }
	
	// Send Broadcast Message
	public func sendMessage(message: String) -> Bool
	{
		var success = false
		
		// Return false if we are not properly connected to a device, handle retry logic in the view for now
		if connectedPeripheral == nil || connectedPeripheral!.peripheral.state != CBPeripheralState.connected {
		
			self.disconnectDevice()
			self.startScanning()
			
			// Try and connect to the preferredPeripherial first
			let preferredPeripheral = peripherals.filter({ $0.peripheral.identifier.uuidString == UserDefaults.standard.object(forKey: "preferredPeripheralId") as? String ?? "" }).first
			if preferredPeripheral != nil && preferredPeripheral?.peripheral != nil {
				connectTo(peripheral: preferredPeripheral!.peripheral)
			} else {
			
				// Try and connect to the last connected device
				let lastConnectedPeripheral = peripherals.filter({ $0.peripheral.identifier.uuidString == self.lastConnectedPeripheral }).first
				if lastConnectedPeripheral != nil && lastConnectedPeripheral?.peripheral != nil {
					connectTo(peripheral: lastConnectedPeripheral!.peripheral)
				}
			}
			success = false
		}
		else if message.count < 1 {
			// Don's send an empty message
			success = false
		}
		else {

			var longName: String = self.connectedPeripheral.name
			var shortName: String = "???"
			var nodeNum: UInt32 = self.connectedPeripheral.myInfo?.myNodeNum ?? 0
			
			if connectedNode != nil {
				longName = connectedNode.user.longName
				shortName = connectedNode.user.shortName
				nodeNum = connectedNode.num
			}
			
			let messageModel = MessageModel(messageId: 0, messageTimeStamp: UInt32(Date().timeIntervalSince1970), fromUserId: nodeNum, toUserId: broadcastNodeId, fromUserLongName: longName, toUserLongName: "Broadcast", fromUserShortName: shortName, toUserShortName: "BC", receivedACK: false, messagePayload: message, direction: "OUT")
			let dataType = PortNum.textMessageApp
			let payloadData: Data = message.data(using: String.Encoding.utf8)!
		
			var dataMessage = DataMessage()
			dataMessage.payload = payloadData
			dataMessage.portnum = dataType
			
			var meshPacket = MeshPacket()
			meshPacket.to = broadcastNodeId
			meshPacket.decoded = dataMessage
			meshPacket.wantAck = true
			
			var toRadio: ToRadio!
			toRadio = ToRadio()
			toRadio.packet = meshPacket

			let binaryData: Data = try! toRadio.serializedData()
			if (connectedPeripheral!.peripheral.state == CBPeripheralState.connected)
			{
				connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
				messageData.messages.append(messageModel)
				messageData.save()
				success = true
			}
		}
		return success
	}
    
}

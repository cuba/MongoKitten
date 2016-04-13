//
//  Database.swift
//  MongoSwift
//
//  Created by Joannis Orlandos on 27/01/16.
//  Copyright © 2016 PlanTeam. All rights reserved.
//

import MD5
import SCRAM
import SHA1
import Foundation
import PBKDF2
import BSON
import HMAC

/// A Mongo Database. Cannot be publically initialized. But you can get a database object by subscripting a Server with a String
public class Database {
    /// The server that this Database is a part of
    public let server: Server
    
    /// The database's name
    public let name: String
    
    /// Are we authenticated?
    public internal(set) var isAuthenticated = true
    
    /// Initialise this database object
    /// - parameter database: The database to use
    /// - parameter server: The server on which this database exists
    internal init(database: String, at server: Server) {
        self.server = server
        self.name = replaceOccurrences(in: database, where: ".", with: "")
    }
    
    /// This subscript is used to get a collection by providing a name as a String
    /// - parameter collection: The collection/bucket to return
    /// - returns: The requested collection in this database
    public subscript (collection: String) -> Collection {
        return Collection(named: collection, in: self)
    }
    
    /// Gets all documents from a reply and throws if it's not a reply
    /// - parameter in: The message in which we'll find the documents
    /// - returns: The documents
    @warn_unused_result
    internal func allDocuments(in message: Message) throws -> [Document] {
        guard case .Reply(_, _, _, _, _, _, let documents) = message else {
            throw InternalMongoError.IncorrectReply(reply: message)
        }
        
        return documents
    }
    
    /// Gets all documents from a reply and throws if it's not a reply
    /// - parameter in: The message in which we'll find the documents
    /// - returns: The first found document
    @warn_unused_result
    internal func firstDocument(in message: Message) throws -> Document {
        let documents = try allDocuments(in: message)
        
        guard let document = documents.first else {
            throw InternalMongoError.IncorrectReply(reply: message)
        }
        
        return document
    }
    
    /// Executes a command on this database using a query message
    /// - parameter command: The command Document to execute
    /// - returns: A message containing the response
    @warn_unused_result
    internal func execute(command command: Document, until timeout: NSTimeInterval = 60) throws -> Message {
        let cmd = self["$cmd"]
        let commandMessage = Message.Query(requestID: server.nextMessageID(), flags: [], collection: cmd, numbersToSkip: 0, numbersToReturn: 1, query: command, returnFields: nil)
        let id = try server.send(message: commandMessage)
        return try server.await(response: id, until: timeout)
    }
    
    /// All information about the collecitons in this Database
    /// - parameter filter: The filter to apply when searching for this information
    /// - returns: A cursor to the resulting documents with collection info
    @warn_unused_result
    public func getCollectionInfos(filter filter: Document? = nil) throws -> Cursor<Document> {
        var request: Document = ["listCollections": 1]
        if let filter = filter {
            request["filter"] = filter
        }
        
        let reply = try execute(command: request)
        
        let result = try firstDocument(in: reply)
        
        guard let code = result["ok"]?.intValue, cursor = result["cursor"] as? Document where code == 1 else {
            throw MongoError.CommandFailure
        }
        
        return try Cursor(cursorDocument: cursor, server: server, chunkSize: 10, transform: { $0 })
    }
    
    /// Gets the collections in this database
    /// - parameter filter: The filter to apply when looking for Collections
    @warn_unused_result
    public func getCollections(filter filter: Document? = nil) throws -> Cursor<Collection> {
        let infoCursor = try self.getCollectionInfos(filter: filter)
        return Cursor(base: infoCursor) { collectionInfo in
            guard let name = collectionInfo["name"]?.stringValue else { return nil }
            return self[name]
        }
    }
    
    /// Looks for `ismaster` information
    /// - returns: `ismaster` response Document
    @warn_unused_result
    internal func isMaster() throws -> Document {
        let response = try self.execute(command: ["ismaster": Int32(1)])
        
        return try firstDocument(in: response)
    }
}

/// Authentication and encryption
extension Database {
    /// Generates a random String
    private func randomNonce() -> String {
        let allowedCharacters = "!\"#'$%&()*+-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_$"
        
        var randomString = ""
        
        for _ in 0..<24 {
            let randomNumber: Int
            
            #if os(Linux)
                randomNumber = Int(random() % allowedCharacters.characters.count)
            #else
                randomNumber = Int(arc4random_uniform(UInt32(allowedCharacters.characters.count)))
            #endif
            
            let letter = allowedCharacters[allowedCharacters.startIndex.advanced(by: randomNumber)]
            
            randomString.append(letter)
        }
        
        return randomString
    }
    
    /// Parses a SCRAM response
    private func parseResponse(response: String) -> [String: String] {
        var parsedResponse = [String: String]()
        
        for part in response.characters.split(separator: ",") where String(part).characters.count >= 3 {
            let part = String(part)
            
            if let first = part.characters.first {
                parsedResponse[String(first)] = part[part.startIndex.advanced(by: 2)..<part.endIndex]
            }
        }
        
        return parsedResponse
    }
    
    /// Last step(s) in the SASL process
    /// TODO: Set a timeout for connecting
    private func complete(SASL payload: String, using response: Document, verifying signature: [Byte]) throws {
        // If we failed authentication
        guard response["ok"]?.int32Value == 1 else {
            throw MongoAuthenticationError.IncorrectCredentials
        }
        
        // If we're done
        if response["done"]?.boolValue == true {
            return
        }
        
        guard let stringResponse = response["payload"]?.stringValue else {
            throw MongoAuthenticationError.AuthenticationFailure
        }
        
        guard let conversationId = response["conversationId"] else {
            throw MongoAuthenticationError.AuthenticationFailure
        }
        
        guard let finalResponse = String(bytes: [Byte](base64: stringResponse), encoding: NSUTF8StringEncoding) else {
            throw MongoAuthenticationError.Base64Failure
        }
        
        let dictionaryResponse = self.parseResponse(finalResponse)
        
        guard let v = dictionaryResponse["v"]?.stringValue else {
            throw MongoAuthenticationError.AuthenticationFailure
        }
        
        let serverSignature = [Byte](base64: v)
        
        guard serverSignature == signature else {
            throw MongoAuthenticationError.ServerSignatureInvalid
        }
        
        let response = try self.execute(command: [
                                                   "saslContinue": Int32(1),
                                                   "conversationId": conversationId,
                                                   "payload": ""
            ])
        
        guard case .Reply(_, _, _, _, _, _, let documents) = response, let responseDocument = documents.first else {
            throw InternalMongoError.IncorrectReply(reply: response)
        }
        
        try self.complete(SASL: payload, using: responseDocument, verifying: serverSignature)
    }
    
    /// Respond to a challenge
    /// TODO: Set a timeout for connecting
    private func challenge(with details: (username: String, password: String), using previousInformation: (nonce: String, response: Document, scram: SCRAMClient<SHA1>)) throws {
        // If we failed the authentication
        guard previousInformation.response["ok"]?.int32Value == 1 else {
            throw MongoAuthenticationError.IncorrectCredentials
        }
        
        // If we're done
        if previousInformation.response["done"]?.boolValue == true {
            return
        }
        
        // Get our ConversationID
        guard let conversationId = previousInformation.response["conversationId"] else {
            throw MongoAuthenticationError.AuthenticationFailure
        }
        
        // Decode the challenge
        guard let stringResponse = previousInformation.response["payload"]?.stringValue else {
            throw MongoAuthenticationError.AuthenticationFailure
        }
        
        guard let decodedStringResponse = String(bytes: [Byte](base64: stringResponse), encoding: NSUTF8StringEncoding) else {
            throw MongoAuthenticationError.Base64Failure
        }
        
        var digestBytes = [Byte]()
        digestBytes.append(contentsOf: "\(details.username):mongo:\(details.password)".utf8)
        
        var passwordBytes = [Byte]()
        passwordBytes.append(contentsOf: MD5.calculate(digestBytes).toHexString().utf8)
        
        let result = try previousInformation.scram.process(challenge: decodedStringResponse, with: (username: details.username, password: passwordBytes), usingNonce: previousInformation.nonce)
        
        
        // Base64 the payload
        guard let payload = result.proof.cStringBsonData.toBase64() else {
            throw MongoAuthenticationError.Base64Failure
        }
        
        // Send the proof
        let response = try self.execute(command: [
                                                   "saslContinue": Int32(1),
                                                   "conversationId": conversationId,
                                                   "payload": payload
            ])
        
        // If we don't get a correct reply
        guard case .Reply(_, _, _, _, _, _, let documents) = response, let responseDocument = documents.first else {
            throw InternalMongoError.IncorrectReply(reply: response)
        }
        
        // Complete Authentication
        try self.complete(SASL: payload, using: responseDocument, verifying: result.serverSignature)
    }
    
    /// Authenticates to this database using SASL
    /// TODO: Support authentication DBs
    /// TODO: Set a timeout for connecting
    internal func authenticate(SASL details: (username: String, password: String)) throws {
        let nonce = randomNonce()
        
        let auth = SCRAMClient<SHA1>()
        
        let authPayload = try auth.authenticate(details.username, usingNonce: nonce)
        
        guard let payload = authPayload.cStringBsonData.toBase64() else {
            throw MongoAuthenticationError.Base64Failure
        }
        
        let response = try self.execute(command: [
                                                   "saslStart": Int32(1),
                                                   "mechanism": "SCRAM-SHA-1",
                                                   "payload": payload
            ])
        
        let responseDocument = try firstDocument(in: response)
        
        try self.challenge(with: details, using: (nonce: nonce, response: responseDocument, scram: auth))
    }
    
    /// Authenticate with MongoDB Challenge Response
    /// TODO: Set a timeout for connecting
    internal func authenticate(mongoCR details: (username: String, password: String)) throws {
        // Get the server's nonce
        let response = try self.execute(command: [
                                                   "getNonce": Int32(1)
            ])
        
        // Get the server's challenge
        let document = try firstDocument(in: response)
        
        guard let nonce = document["nonce"]?.stringValue else {
            throw MongoAuthenticationError.AuthenticationFailure
        }
        
        // Digest our password and prepare it for sending
        var bytes = [Byte]()
        bytes.append(contentsOf: "\(details.username):mongo:\(details.password)".utf8)
        
        let digest = MD5.calculate(bytes).toHexString()
        let key = MD5.calculate("\(nonce)\(details.username)\(digest)".cStringBsonData).toHexString()
        
        // Respond to the challengge
        let successResponse = try self.execute(command: [
                                                          "authenticate": 1,
                                                          "nonce": nonce,
                                                          "user": details.username,
                                                          "key": key
            ])
        
        let successDocument = try firstDocument(in: successResponse)
        
        // Check for success
        guard let ok = successDocument["ok"]?.intValue where ok == 1 else {
            throw InternalMongoError.IncorrectReply(reply: successResponse)
        }
    }
}
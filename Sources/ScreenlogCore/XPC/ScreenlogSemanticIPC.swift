import Foundation

extension IPCRequest {
    func validateSemanticRequest() throws {
        let isSemantic = cmd == .semanticStatus || cmd == .semanticSearch || cmd == .semanticControl
        guard isSemantic else {
            guard semanticSearch == nil, semanticControl == nil else {
                throw IPCRequestValidationError.invalid("semantic payload requires a semantic command")
            }
            return
        }
        guard (protocolMinimumVersion ?? 0) >= ScreenlogIPCProtocol.semanticSearchVersion else {
            throw IPCRequestValidationError.invalid("semantic commands require IPC protocol 3; update the app and CLI together")
        }
        guard query == nil, searchContent == nil, literalSearch == nil, limit == nil,
            minSegLen == nil, gapMinutes == nil, frameID == nil, frameIDs == nil,
            timestampMs == nil, fromTimestampMs == nil, toTimestampMs == nil,
            sortOrder == nil, contextBeforeCount == nil, contextAfterCount == nil,
            outPath == nil, preferBase64 == nil
        else { throw IPCRequestValidationError.invalid("semantic commands do not accept legacy command fields") }
        switch cmd {
        case .semanticStatus:
            guard semanticSearch == nil, semanticControl == nil else {
                throw IPCRequestValidationError.invalid("semantic status does not accept a payload")
            }
        case .semanticSearch:
            guard let request = semanticSearch, semanticControl == nil else {
                throw IPCRequestValidationError.invalid("semantic search requires only a search payload")
            }
            let parsed = SearchOperatorParser.parse(request.query)
            if let issue = parsed.validationIssue { throw IPCRequestValidationError.invalid(issue) }
            let text = parsed.ftsText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, request.query.utf8.count <= IPCRequestLimits.maximumQueryBytes,
                !request.query.utf8.contains(0)
            else { throw IPCRequestValidationError.invalid("semantic query must contain text and at most 4096 bytes, without NUL bytes") }
            guard IPCRequestLimits.resultLimit.contains(request.limit) else {
                throw IPCRequestValidationError.invalid("limit must be between 1 and 500")
            }
            for value in [request.appFilter, request.siteFilter, request.appBundleID, request.domain].compactMap({ $0 }) {
                guard !value.isEmpty, value.utf8.count <= IPCRequestLimits.maximumQueryBytes, !value.utf8.contains(0) else {
                    throw IPCRequestValidationError.invalid("semantic filters must contain 1...4096 bytes without NUL bytes")
                }
            }
            if let from = request.fromTimestampMs, let to = request.toTimestampMs, from >= to {
                throw IPCRequestValidationError.invalid("the semantic range start must be earlier than its end")
            }
        case .semanticControl:
            guard let request = semanticControl, semanticSearch == nil else {
                throw IPCRequestValidationError.invalid("semantic control requires only a control payload")
            }
            switch request.action {
            case .downloadModels, .enable:
                guard request.mode != nil else { throw IPCRequestValidationError.invalid("this semantic action requires a mode") }
            case .disable, .pause, .resume, .indexNow, .removeIndex, .removeModels:
                guard request.mode == nil else { throw IPCRequestValidationError.invalid("this semantic action does not accept a mode") }
            }
            guard !request.enableWhenReady || request.action == .downloadModels else {
                throw IPCRequestValidationError.invalid("enableWhenReady requires an explicit model download")
            }
        default: break
        }
    }
}

extension SemanticSearchError {
    var ipcErrorCode: IPCResponseErrorCode {
        switch self {
        case .disabled: return .semanticDisabled
        case .modelMissing: return .semanticModelMissing
        case .indexEmpty: return .semanticIndexEmpty
        case .unavailable: return .semanticUnavailable
        case .invalidRequest: return .semanticInvalidRequest
        }
    }
}

extension IPCResponse {
    var semanticError: SemanticSearchError? {
        switch errorCode.flatMap(IPCResponseErrorCode.init(rawValue:)) {
        case .semanticDisabled: return .disabled
        case .semanticModelMissing: return .modelMissing
        case .semanticIndexEmpty: return .indexEmpty
        case .semanticUnavailable: return .unavailable(error ?? "Semantic search is unavailable.")
        case .semanticInvalidRequest: return .invalidRequest(error ?? "The semantic request is invalid.")
        default: return nil
        }
    }
}

extension ScreenlogSocketClient {
    public func semanticStatus() throws -> SemanticFeatureStatus {
        try semanticPayload(IPCRequest(cmd: .semanticStatus, protocolMinimumVersion: ScreenlogIPCProtocol.semanticSearchVersion))
    }

    public func semanticSearch(_ request: SemanticSearchRequest) throws -> SemanticSearchResponse {
        try semanticPayload(
            IPCRequest(cmd: .semanticSearch, protocolMinimumVersion: ScreenlogIPCProtocol.semanticSearchVersion, semanticSearch: request))
    }

    public func semanticControl(_ request: SemanticControlRequest) throws -> SemanticFeatureStatus {
        try semanticPayload(
            IPCRequest(cmd: .semanticControl, protocolMinimumVersion: ScreenlogIPCProtocol.semanticSearchVersion, semanticControl: request))
    }

    private func semanticPayload<T: Decodable>(_ request: IPCRequest) throws -> T {
        guard let data = try call(request).data else { throw XPCClientError.remote("The app returned no semantic response.") }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

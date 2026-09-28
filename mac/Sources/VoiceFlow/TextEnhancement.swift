import Foundation


enum EnhancementOperation: String, Identifiable, Sendable {

    case clean
    case concise
    case business
    case grammar
    case translate
    case tone
    case structure
    case instruction

    case smartDictation = "smart_dictation"

    var id: String { rawValue }

    static let quickActions: [EnhancementOperation] = [
        .translate, .concise, .tone, .structure,
    ]
}

struct EnhancementUsage: Equatable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
    let cachedInputTokens: Int?
    let reasoningTokens: Int?
}


struct EnhancementPreviewResult: Equatable, Sendable {
    let status: String
    let readyForPreview: Bool
    let candidate: String
    let operation: EnhancementOperation
    let latencyMS: Int
    let errorCode: String?
    let validationIssues: [String]
    let validationWarnings: [String]
    let instruction: String?
    let usage: EnhancementUsage?
    let providerFailureStage: String?

    init(
        status: String,
        readyForPreview: Bool,
        candidate: String,
        operation: EnhancementOperation,
        latencyMS: Int,
        errorCode: String?,
        validationIssues: [String],
        validationWarnings: [String],
        instruction: String?,
        usage: EnhancementUsage? = nil,
        providerFailureStage: String? = nil
    ) {
        self.status = status
        self.readyForPreview = readyForPreview
        self.candidate = candidate
        self.operation = operation
        self.latencyMS = latencyMS
        self.errorCode = errorCode
        self.validationIssues = validationIssues
        self.validationWarnings = validationWarnings
        self.instruction = instruction
        self.usage = usage
        self.providerFailureStage = providerFailureStage.flatMap {
            ["connect", "read", "handshake_or_read", "timeout", "tls", "transport", "http", "response"].contains($0) ? $0 : nil
        }
    }

    static func decode(
        line: String,
        original: String,
        requestedOperation: EnhancementOperation
    ) -> EnhancementPreviewResult {
        guard
            let data = line.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = root["enhancement_preview"] as? [String: Any]
        else {
            return fallback(
                original: original,
                operation: requestedOperation,
                errorCode: "invalid_response"
            )
        }

        let status = payload["status"] as? String ?? "fallback"
        let returnedOperation = payload["operation"] as? String
        let latency = (payload["latency_ms"] as? NSNumber)?.intValue ?? 0
        let issues = payload["validation_issues"] as? [String] ?? []
        let warnings = payload["validation_warnings"] as? [String] ?? []
        let backendError = payload["error_code"] as? String
        let failureStage = (payload["provider_diagnostics"] as? [String: Any])?["failure_stage"] as? String
        let instruction = (payload["instruction"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usage: EnhancementUsage? = {
            guard let raw = payload["usage"] as? [String: Any] else { return nil }
            let value = EnhancementUsage(
                inputTokens: (raw["input_tokens"] as? NSNumber)?.intValue,
                outputTokens: (raw["output_tokens"] as? NSNumber)?.intValue,
                totalTokens: (raw["total_tokens"] as? NSNumber)?.intValue,
                cachedInputTokens: (raw["cached_input_tokens"] as? NSNumber)?.intValue,
                reasoningTokens: (raw["reasoning_tokens"] as? NSNumber)?.intValue
            )
            return value.inputTokens == nil
                && value.outputTokens == nil
                && value.totalTokens == nil
                && value.cachedInputTokens == nil
                && value.reasoningTokens == nil
                ? nil : value
        }()

        guard returnedOperation == requestedOperation.rawValue else {
            return EnhancementPreviewResult(
                status: "fallback",
                readyForPreview: false,
                candidate: original,
                operation: requestedOperation,
                latencyMS: latency,
                errorCode: "operation_mismatch",
                validationIssues: issues,
                validationWarnings: warnings,
                instruction: instruction,
                usage: usage,
                providerFailureStage: failureStage
            )
        }

        let backendReady = payload["ready_for_preview"] as? Bool ?? false
        let candidate = payload["candidate"] as? String
        let instructionIsValid = requestedOperation != .instruction || !(instruction ?? "").isEmpty
        if status == "ready",
           backendReady,
           let candidate,
           !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           instructionIsValid {
            return EnhancementPreviewResult(
                status: status,
                readyForPreview: true,
                candidate: candidate,
                operation: requestedOperation,
                latencyMS: latency,
                errorCode: nil,
                validationIssues: issues,
                validationWarnings: warnings,
                instruction: instruction,
                usage: usage,
                providerFailureStage: failureStage
            )
        }

        let errorCode: String
        if let backendError, !backendError.isEmpty {
            errorCode = backendError
        } else if status == "ready" && backendReady {
            errorCode = "invalid_candidate"
        } else {
            errorCode = "preview_not_ready"
        }
        return EnhancementPreviewResult(
            status: status,
            readyForPreview: false,
            candidate: original,
            operation: requestedOperation,
            latencyMS: latency,
            errorCode: errorCode,
            validationIssues: issues,
            validationWarnings: warnings,
            instruction: instruction,
            usage: usage,
            providerFailureStage: failureStage
        )
    }

    static func transportFailure(
        original: String,
        operation: EnhancementOperation
    ) -> EnhancementPreviewResult {
        fallback(original: original, operation: operation, errorCode: "daemon")
    }

    static func localFailure(
        original: String,
        operation: EnhancementOperation,
        errorCode: String
    ) -> EnhancementPreviewResult {
        fallback(original: original, operation: operation, errorCode: errorCode)
    }

    private static func fallback(
        original: String,
        operation: EnhancementOperation,
        errorCode: String
    ) -> EnhancementPreviewResult {
        EnhancementPreviewResult(
            status: "fallback",
            readyForPreview: false,
            candidate: original,
            operation: operation,
            latencyMS: 0,
            errorCode: errorCode,
            validationIssues: [],
            validationWarnings: [],
            instruction: nil
        )
    }
}


enum EnhancementFailureMessage {
    static func message(code: String, stage: String? = nil) -> String {
        switch code {
        case "no_polish_key", "missing_credentials", "provider_auth_failed":
            return L("文字模型凭据不可用，请在设置中检查；原文没有改变。", "The text-model credential is unavailable. Check Settings; the original is unchanged.")
        case "text_enhancement_disabled":
            return L("请先在设置中启用文字增强；原文没有改变。", "Enable text enhancement in Settings first; the original is unchanged.")
        case "cancelled":
            return L("已取消本次润色，原文没有改变。", "Refinement was cancelled; the original is unchanged.")
        case "provider_bad_request":
            return L("文字服务未接受本次请求（HTTP 400）；具体原因尚不明确，原文没有改变。", "The text service rejected this request (HTTP 400); the specific reason is unknown. The original is unchanged.")
        case "provider_content_rejected":
            return L("文字服务因内容审核拒绝处理；没有生成可用候选，原文没有改变。", "The text service rejected the request under its content policy; no usable candidate was returned. The original is unchanged.")
        case "provider_timeout":
            switch stage {
            case "connect":
                return L("连接文字服务超时；原文没有改变。请检查网络后手动重试。", "Connecting to the text service timed out; the original is unchanged. Check the connection and retry manually.")
            case "read", "handshake_or_read":
                return L("连接或等待文字服务响应超时；原文没有改变。请稍后手动重试。", "The connection or response wait timed out; the original is unchanged. Retry manually later.")
            default:
                return L("文字服务请求超时；原文没有改变。请稍后手动重试。", "The text service request timed out; the original is unchanged. Retry manually later.")
            }
        case "provider_output_truncated":
            return L("文字服务返回的内容被截断，未采用不完整结果；原文没有改变。", "The text service returned a truncated response. The incomplete result was not applied; the original is unchanged.")
        case "provider_network_error":
            if stage == "tls" {
                return L("文字服务安全连接失败；原文没有改变。请检查网络后手动重试。", "The secure connection to the text service failed; the original is unchanged. Check the connection and retry manually.")
            }
            return L("文字服务连接中断；原文没有改变。请检查网络后手动重试。", "The connection to the text service was interrupted; the original is unchanged. Check the connection and retry manually.")
        case "provider_invalid_response", "invalid_response":
            return L("文字服务未返回可用的结果格式；原文没有改变。", "No usable response format was returned; the original is unchanged.")
        default:
            return L("未能完成文字处理；原文没有改变。", "Text processing could not be completed; the original is unchanged.")
        }
    }
}

import Foundation

extension AssistantContinuity {
    func serverContinuationAnchorRemoved() -> AssistantContinuity {
        if let replayState = try? ResponsesReplayState(continuity: self) {
            return ResponsesReplayState(
                output: replayState.output,
                responseId: nil
            ).continuity
        }
        guard case var .object(payload) = payload,
              payload["response_id"] != nil
        else {
            return self
        }
        payload.removeValue(forKey: "response_id")
        return AssistantContinuity(substrate: substrate, payload: .object(payload))
    }

    func terminalFinishToolRemoved() -> AssistantContinuity {
        guard case let .object(payload) = payload,
              case let .array(output) = payload["output"]
        else {
            return self
        }

        let filteredOutput = output.filter { item in
            guard case let .object(object) = item,
                  case let .string(type) = object["type"],
                  type == "function_call",
                  case let .string(name) = object["name"]
            else {
                return true
            }
            return name != "finish"
        }

        guard filteredOutput.count != output.count else {
            return self
        }

        var updatedPayload = payload
        updatedPayload["output"] = .array(filteredOutput)
        return AssistantContinuity(substrate: substrate, payload: .object(updatedPayload))
            .serverContinuationAnchorRemoved()
    }
}

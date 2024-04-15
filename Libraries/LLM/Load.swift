// Copyright © 2024 Apple Inc.

import AsyncAlgorithms
import Foundation
import Hub
import MLX
import MLXNN
import MLXRandom
import Tokenizers

struct LLMError: Error {
    let message: String
}

/// Load and return the model and tokenizer
public func load(
    hub: HubApi = HubApi(), configuration: ModelConfiguration,
    progressHandler: @escaping (Progress) -> Void = { _ in }
) async throws -> (LLMModel, Tokenizer) {
    do {
        let tokenizer = try await loadTokenizer(configuration: configuration, hub: hub)

        let modelDirectory: URL

        switch configuration.id {
        case .id(let id):
            // download the model weights and config
            let repo = Hub.Repo(id: id)
            let modelFiles = ["config.json", "*.safetensors"]
            modelDirectory = try await hub.snapshot(
                from: repo, matching: modelFiles, progressHandler: progressHandler)

        case .directory(let directory):
            modelDirectory = directory
        }

        // create the model (no weights loaded)
        let configurationURL = modelDirectory.appending(component: "config.json")
        let baseConfig = try JSONDecoder().decode(
            BaseConfiguration.self, from: Data(contentsOf: configurationURL))

        let model = try baseConfig.modelType.createModel(configuration: configurationURL)

        // load the weights
        var weights = [String: MLXArray]()
        let enumerator = FileManager.default.enumerator(
            at: modelDirectory, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator {
            if url.pathExtension == "safetensors" {
                let w = try loadArrays(url: url)
                for (key, value) in w {
                    weights[key] = value
                }
            }
        }

        // quantize if needed
        if let quantization = baseConfig.quantization {
            quantizeIfNeeded(model: model, weights: weights, quantization: quantization)
        }

        // apply the loaded weights
        let parameters = ModuleParameters.unflattened(weights)
        try model.update(parameters: parameters, verify: [.all])

        eval(model)

        return (model, tokenizer)

    } catch Hub.HubClientError.authorizationRequired {
        // an authorizationRequired means (typically) that the named repo doesn't exist on
        // on the server so retry with local only configuration
        var newConfiguration = configuration
        newConfiguration.id = .directory(configuration.modelDirectory(hub: hub))
        return try await load(
            hub: hub, configuration: newConfiguration, progressHandler: progressHandler)
    }
}

// MARK: - Quantization

private func quantizeIfNeeded(
    model: LLMModel, weights: [String: MLXArray], quantization: BaseConfiguration.Quantization
) {

    func linearPredicate(layer: Module) -> Bool {
        if let layer = layer as? Linear {
            // avoid quantizing gate layers, otherwise we have to re-quant and upload all the mixtral models
            return layer.weight.dim(0) != 8
        }
        return false
    }

    var predicate = linearPredicate(layer:)

    // for legacy models that don't have lm_head quant due to non-32 dims
    if weights["lm_head.scales"] == nil {
        let vocabularySize = model.vocabularySize

        func vocabularySizePredicate(layer: Module) -> Bool {
            if let layer = layer as? Linear {
                return layer.weight.dim(0) != 8 && layer.weight.dim(0) != vocabularySize
            }
            return false
        }

        predicate = vocabularySizePredicate(layer:)
    }

    QuantizedLinear.quantize(
        model: model, groupSize: quantization.groupSize, bits: quantization.bits,
        predicate: predicate)
}

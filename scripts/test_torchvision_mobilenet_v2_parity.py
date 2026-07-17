#!/usr/bin/env python3
"""Differential parity test: PyTorch MobileNetV2 versus Swift-emitted Core ML.

Run with an environment containing torch, torchvision, numpy, and coremltools:

    python scripts/test_torchvision_mobilenet_v2_parity.py
"""

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

import numpy as np
import torch
from torch.fx import Interpreter, symbolic_trace
from torchvision.models import MobileNet_V2_Weights, mobilenet_v2


REPOSITORY = Path(__file__).resolve().parents[1]
EXPORTER = REPOSITORY / "scripts" / "export_torchvision_mobilenet_v2.py"
EVALUATOR = "native-model-evaluator"
# Core ML and PyTorch execute the same Float32 graph with different kernel/reduction orders.
# The budget covers the accumulated error of a full pretrained MobileNetV2 on CPU; it is not used
# to mask graph differences because every rank-preserving intermediate tensor is checked too.
ATOL = 1e-4
RTOL = 1e-4


def fixed_inputs():
    generator = torch.Generator().manual_seed(17)
    return {
        "zeros": torch.zeros(1, 3, 224, 224),
        "seeded_normal": torch.randn((1, 3, 224, 224), generator=generator),
        "ramp": torch.linspace(-1, 1, 3 * 224 * 224).reshape(1, 3, 224, 224),
    }


def write_graph_and_refresh_manifest(package: Path, graph: dict) -> None:
    """Update a test graph without invalidating the package-integrity contract."""
    graph_data = json.dumps(graph, separators=(",", ":")).encode()
    (package / "graph.json").write_bytes(graph_data)
    manifest_path = package / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["graphSHA256"] = hashlib.sha256(graph_data).hexdigest()
    manifest_path.write_text(json.dumps(manifest, separators=(",", ":")))


def assert_logits_match(actual: np.ndarray, expected: np.ndarray, description: str) -> None:
    np.testing.assert_allclose(actual, expected, rtol=RTOL, atol=ATOL, err_msg=description)
    np.testing.assert_array_equal(
        np.argmax(actual, axis=1),
        np.argmax(expected, axis=1),
        err_msg=f"{description}: top-1 class changed",
    )


def report_intermediate_errors(core_ml_outputs: dict, captured_values: dict, outputs: list[str], input_name: str) -> None:
    errors = sorted(
        (
            float(np.max(np.abs(core_ml_outputs[output] - captured_values[output]))),
            output,
        )
        for output in outputs
    )
    print(f"{input_name}: largest intermediate errors: " + ", ".join(
        f"{output}={error:.9g}" for error, output in errors[-5:][::-1]
    ))


class CapturingInterpreter(Interpreter):
    def __init__(self, module):
        super().__init__(module)
        self.values = {}

    def run_node(self, node):
        value = super().run_node(node)
        if isinstance(value, torch.Tensor):
            self.values[node.name] = value.detach().cpu().clone().numpy()
        return value


def make_source_model(pretrained: bool, classifier_gain: float, float16_weights: bool):
    torch.manual_seed(0)
    weights = MobileNet_V2_Weights.IMAGENET1K_V1 if pretrained else None
    model = mobilenet_v2(weights=weights).eval()
    with torch.no_grad():
        model.classifier[1].weight.mul_(classifier_gain)
        model.classifier[1].bias.mul_(classifier_gain)
        if float16_weights:
            for tensor in list(model.parameters()) + list(model.buffers()):
                tensor.copy_(tensor.half().float())
    return model


def native_predict_many(
    model_path: Path,
    input_tensors: dict[str, torch.Tensor],
    temporary_directory: Path,
) -> dict[str, dict[str, np.ndarray]]:
    identifier = uuid.uuid4().hex
    output_directory = temporary_directory / f"outputs-{identifier}"
    input_paths = []
    for index, input_tensor in enumerate(input_tensors.values()):
        input_path = temporary_directory / f"input-{identifier}-{index}.f32"
        input_tensor.detach().cpu().contiguous().numpy().astype("<f4", copy=False).tofile(input_path)
        input_paths.append(input_path)
    subprocess.run(
        ["swift", "run", EVALUATOR, str(model_path), str(output_directory), *map(str, input_paths)],
        check=True,
        cwd=REPOSITORY,
    )
    manifest = json.loads((output_directory / "manifest.json").read_text())
    return {
        list(input_tensors)[evaluation["inputIndex"]]: {
            output["name"]: np.fromfile(
                output_directory / f"input-{evaluation['inputIndex']}" / output["file"],
                dtype="<f4",
            ).reshape(output["shape"])
            for output in evaluation["outputs"]
        }
        for evaluation in manifest["evaluations"]
    }


def main(
    intermediates: bool,
    coremltools_reference: bool,
    sensitivity: bool,
    float16_weights: bool,
    pretrained: bool,
    diagnose: bool,
) -> None:
    if coremltools_reference and sensitivity:
        raise ValueError(
            "Run --coremltools-reference and --sensitivity separately: coremltools' legacy "
            "NeuralNetwork backend does not preserve this fixture's amplified logits."
        )
    with tempfile.TemporaryDirectory(prefix="aiarcheology-mobilenet-parity-") as temporary_directory:
        temporary_directory = Path(temporary_directory)
        package = temporary_directory / "MobileNetV2.aiagraph"
        model_path = temporary_directory / "MobileNetV2.mlmodel"
        classifier_gain = 1_000_000 if sensitivity else 1
        weight_dtype = "float16" if float16_weights else "float32"
        exporter_command = [
            sys.executable,
            str(EXPORTER),
            str(package),
            "--classifier-gain",
            str(classifier_gain),
            "--weight-dtype",
            weight_dtype,
        ]
        if pretrained:
            exporter_command.append("--pretrained")
        subprocess.run(exporter_command, check=True)
        subprocess.run(
            ["swift", "run", "native-model-converter", str(package), str(model_path)],
            check=True,
            cwd=REPOSITORY,
        )

        graph = json.loads((package / "graph.json").read_text())
        final_output_name = graph["outputs"][0]
        if intermediates:
            # Core ML's legacy Flatten layer changes its internal rank but cannot expose that
            # rank-changing blob as an external feature. The final classifier output still checks
            # Flatten/Linear composition; every rank-preserving emitted tensor is exposed here.
            graph["outputs"] = [
                operation["outputs"][0]["name"]
                for operation in graph["operations"]
                if operation["kind"] != "flatten"
            ]
            write_graph_and_refresh_manifest(package, graph)
            subprocess.run(
                ["swift", "run", "native-model-converter", str(package), str(model_path)],
                check=True,
                cwd=REPOSITORY,
            )
        input_name = graph["inputs"][0]["name"]
        output_name = final_output_name
        source_model = make_source_model(pretrained, classifier_gain, float16_weights)
        reference_model = None
        reference_output_name = None
        if coremltools_reference:
            import coremltools as ct

            traced = torch.jit.trace(source_model, torch.zeros(1, 3, 224, 224))
            reference_model = ct.convert(
                traced,
                inputs=[ct.TensorType(name=input_name, shape=(1, 3, 224, 224))],
                convert_to="mlprogram",
                minimum_deployment_target=ct.target.macOS14,
                compute_precision=ct.precision.FLOAT32,
            )
            reference_output_name = next(iter(reference_model.predict({input_name: np.zeros((1, 3, 224, 224), dtype=np.float32)})))

        fixed_input_tensors = fixed_inputs()
        if intermediates:
            # Exposing every MobileNet tensor is intentionally diagnostic. Evaluate one fixed
            # input at a time so the Core ML process does not retain all exposed tensors for every
            # input simultaneously.
            native_outputs = {
                name: native_predict_many(model_path, {name: input_tensor}, temporary_directory)[name]
                for name, input_tensor in fixed_input_tensors.items()
            }
        else:
            native_outputs = native_predict_many(model_path, fixed_input_tensors, temporary_directory)
        for name, input_tensor in fixed_input_tensors.items():
            with torch.no_grad():
                expected = source_model(input_tensor).numpy()
            core_ml_outputs = native_outputs[name]
            actual = core_ml_outputs[output_name]
            capture = None
            if intermediates:
                capture = CapturingInterpreter(symbolic_trace(source_model))
                capture.run(input_tensor)
                if diagnose:
                    report_intermediate_errors(core_ml_outputs, capture.values, graph["outputs"], name)
            assert_logits_match(actual, expected, name)
            if reference_model is not None:
                reference = reference_model.predict({input_name: input_tensor.numpy()})[reference_output_name]
                assert_logits_match(reference, expected, f"coremltools-source:{name}")
                assert_logits_match(actual, reference, f"coremltools:{name}")
            maximum_error = float(np.max(np.abs(actual - expected)))
            print(f"{name}: max_abs_error={maximum_error:.9g}")
            if intermediates:
                assert capture is not None
                for output in graph["outputs"]:
                    np.testing.assert_allclose(core_ml_outputs[output], capture.values[output], rtol=RTOL, atol=ATOL, err_msg=f"{name}:{output}")
                print(f"{name}: {len(graph['outputs'])} intermediate tensors match")

        if sensitivity:
            if intermediates:
                # Sensitivity validates only the final response. Re-emit without diagnostic
                # outputs before evaluating its four related inputs as one Core ML session.
                graph["outputs"] = [final_output_name]
                write_graph_and_refresh_manifest(package, graph)
                subprocess.run(
                    ["swift", "run", "native-model-converter", str(package), str(model_path)],
                    check=True,
                    cwd=REPOSITORY,
                )
            base = fixed_inputs()["seeded_normal"]
            direction = torch.Generator().manual_seed(23)
            direction = torch.randn(base.shape, generator=direction)
            sensitivity_inputs = {"base": base}
            sensitivity_inputs.update({
                f"epsilon-{epsilon}": base + epsilon * direction
                for epsilon in (1e-4, 1e-3, 1e-2)
            })
            sensitivity_outputs = native_predict_many(model_path, sensitivity_inputs, temporary_directory)
            for epsilon in (1e-4, 1e-3, 1e-2):
                with torch.no_grad():
                    reference_delta = source_model(base + epsilon * direction).numpy() - source_model(base).numpy()
                actual_delta = sensitivity_outputs[f"epsilon-{epsilon}"][output_name] - sensitivity_outputs["base"][output_name]
                np.testing.assert_allclose(actual_delta, reference_delta, rtol=1e-4, atol=1e-6, err_msg=f"sensitivity:{epsilon}")
                print(f"sensitivity epsilon={epsilon:g}: max_abs_error={float(np.max(np.abs(actual_delta - reference_delta))):.9g}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--intermediates", action="store_true", help="compare every emitted FX tensor")
    parser.add_argument("--coremltools-reference", action="store_true", help="compare with an independent coremltools conversion")
    parser.add_argument("--sensitivity", action="store_true", help="compare finite-difference responses with amplified logits")
    parser.add_argument("--float16-weights", action="store_true", help="quantize reference and exported weights to Float16")
    parser.add_argument("--pretrained", action="store_true", help="use torchvision's ImageNet-1K MobileNetV2 checkpoint")
    parser.add_argument("--diagnose", action="store_true", help="print the five largest intermediate errors (requires --intermediates)")
    arguments = parser.parse_args()
    main(
        arguments.intermediates,
        arguments.coremltools_reference,
        arguments.sensitivity,
        arguments.float16_weights,
        arguments.pretrained,
        arguments.diagnose,
    )

#!/usr/bin/env python3
"""Export torchvision MobileNetV2 (eval mode) as a fixed-shape .aiagraph package.

Requires torch, torchvision, and numpy. This is intentionally a reference exporter for the first
native-converter milestone rather than a general-purpose FX lowering framework.
"""

import argparse
import hashlib
import json
import operator
from pathlib import Path

import torch
from torch.fx import Node, symbolic_trace
from torch.fx.passes.shape_prop import ShapeProp
from torchvision.models import mobilenet_v2


def tensor_description(name, meta):
    if meta.dtype not in (torch.float32, torch.float16):
        raise ValueError(f"{name} has unsupported dtype {meta.dtype}")
    return {"name": name, "dataType": "float16" if meta.dtype == torch.float16 else "float32", "shape": list(meta.shape)}


def export(output: Path) -> None:
    # Makes the reference fixture reproducible without downloading pretrained weights.
    torch.manual_seed(0)
    model = mobilenet_v2(weights=None).eval()
    graph_module = symbolic_trace(model)
    ShapeProp(graph_module).propagate(torch.zeros(1, 3, 224, 224))
    output.mkdir(parents=True, exist_ok=False)
    weights_path = output / "weights.bin"
    weights = bytearray()
    descriptors = []
    registered = {}

    def add_weight(name, value):
        if name in registered:
            return name
        value = value.detach().cpu().contiguous()
        if value.dtype not in (torch.float32, torch.float16):
            value = value.float()
        raw = value.numpy().tobytes()
        registered[name] = name
        descriptors.append({"name": name, "dataType": "float16" if value.dtype == torch.float16 else "float32", "shape": list(value.shape), "offset": len(weights), "byteCount": len(raw)})
        weights.extend(raw)
        return name

    operations = []
    tensor_names = {}
    inputs = []
    final_outputs = []

    def input_name(value):
        if not isinstance(value, Node):
            raise ValueError(f"Expected FX tensor input, got {value!r}")
        return tensor_names[value]

    for node in graph_module.graph.nodes:
        meta = node.meta.get("tensor_meta")
        if node.op == "placeholder":
            tensor_names[node] = node.name
            inputs.append(tensor_description(node.name, meta))
            continue
        if node.op == "output":
            values = node.args[0] if isinstance(node.args[0], tuple) else (node.args[0],)
            final_outputs = [input_name(value) for value in values]
            continue
        if node.op == "call_module":
            module = graph_module.get_submodule(node.target)
            if isinstance(module, torch.nn.Dropout):
                tensor_names[node] = input_name(node.args[0])
                continue
            if isinstance(module, torch.nn.Conv2d):
                op, attributes = "conv2d", {"kernelSize": list(module.kernel_size), "strides": list(module.stride), "padding": list(module.padding), "dilations": list(module.dilation), "groups": module.groups}
                node_inputs = [input_name(node.args[0]), add_weight(f"{node.target}.weight", module.weight)]
                if module.bias is not None:
                    node_inputs.append(add_weight(f"{node.target}.bias", module.bias))
            elif isinstance(module, torch.nn.BatchNorm2d):
                op, attributes = "batchNorm", {"epsilon": module.eps}
                node_inputs = [input_name(node.args[0]), add_weight(f"{node.target}.weight", module.weight), add_weight(f"{node.target}.bias", module.bias), add_weight(f"{node.target}.running_mean", module.running_mean), add_weight(f"{node.target}.running_var", module.running_var)]
            elif isinstance(module, torch.nn.ReLU6):
                op, attributes, node_inputs = "relu6", {}, [input_name(node.args[0])]
            elif isinstance(module, torch.nn.Linear):
                op, attributes = "linear", {}
                node_inputs = [input_name(node.args[0]), add_weight(f"{node.target}.weight", module.weight)]
                if module.bias is not None:
                    node_inputs.append(add_weight(f"{node.target}.bias", module.bias))
            else:
                raise ValueError(f"Unsupported MobileNetV2 module {node.target}: {type(module).__name__}")
        elif node.op == "call_function" and node.target in (operator.add, torch.add):
            op, attributes, node_inputs = "add", {}, [input_name(node.args[0]), input_name(node.args[1])]
        elif node.op == "call_function" and node.target is torch.flatten:
            if node.args[1] != 1:
                raise ValueError("Only torch.flatten(start_dim=1) is supported")
            op, attributes, node_inputs = "flatten", {"axis": 1}, [input_name(node.args[0])]
        elif node.op == "call_function" and getattr(node.target, "__name__", "") == "adaptive_avg_pool2d":
            if list(meta.shape[-2:]) != [1, 1]:
                raise ValueError("Only global adaptive average pooling is supported")
            op, attributes, node_inputs = "globalAveragePool2d", {}, [input_name(node.args[0])]
        else:
            raise ValueError(f"Unsupported FX node {node.op}: {node.target}")
        tensor_names[node] = node.name
        operations.append({"name": node.name, "kind": op, "inputs": node_inputs, "outputs": [tensor_description(node.name, meta)], "attributes": attributes})

    weights_path.write_bytes(weights)
    graph = {"formatVersion": 1, "producer": {"name": "aiarcheology-torchvision", "version": torch.__version__}, "inputs": inputs, "weights": descriptors, "operations": operations, "outputs": final_outputs}
    (output / "graph.json").write_text(json.dumps(graph, separators=(",", ":")))
    manifest = {"format": "com.aiarcheology.native-model-graph", "formatVersion": 1, "graph": "graph.json", "weights": "weights.bin", "weightsSHA256": hashlib.sha256(weights).hexdigest()}
    (output / "manifest.json").write_text(json.dumps(manifest, separators=(",", ":")))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path, help="new .aiagraph directory")
    export(parser.parse_args().output)

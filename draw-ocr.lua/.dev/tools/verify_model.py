#!/usr/bin/env python3
"""Verify a CCOCR2 export and report overall and per-class EMNIST accuracy."""

import argparse
import string
import struct
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as functional
from torch.utils.data import DataLoader
from torchvision import datasets, transforms


def load_model(path: Path) -> tuple[tuple[torch.Tensor, ...], int]:
    data = path.read_bytes()
    magic, input_size, channels1, channels2, hidden, classes, pool = struct.unpack_from("<8sIIIIII", data)
    assert magic == b"CCOCR2\0\0"
    assert (input_size, channels1, channels2, hidden, pool) == (28, 16, 32, 96, 2)
    assert classes in (10, 26)
    values = np.frombuffer(data, dtype="<f4", offset=32).copy()
    shapes = (
        (16, 1, 5, 5), (16,), (32, 16, 3, 3), (32,),
        (96, 32 * 5 * 5), (96,), (classes, 96), (classes,),
    )
    assert values.size == sum(int(np.prod(shape)) for shape in shapes)
    offset = 0
    arrays = []
    for shape in shapes:
        count = int(np.prod(shape))
        arrays.append(torch.from_numpy(values[offset:offset + count].reshape(shape)))
        offset += count
    return tuple(arrays), classes


def infer(model: tuple[torch.Tensor, ...], images: torch.Tensor) -> torch.Tensor:
    conv1_w, conv1_b, conv2_w, conv2_b, feature_w, feature_b, output_w, output_b = model
    hidden = functional.max_pool2d(torch.relu(functional.conv2d(images, conv1_w, conv1_b)), 2)
    hidden = functional.max_pool2d(torch.relu(functional.conv2d(hidden, conv2_w, conv2_b)), 2)
    hidden = torch.relu(functional.linear(hidden.flatten(1), feature_w, feature_b))
    return functional.linear(hidden, output_w, output_b)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--split", choices=("letters", "digits"), required=True)
    parser.add_argument("--model", type=Path)
    parser.add_argument("--data", type=Path, default=Path(".data"))
    args = parser.parse_args()
    path = args.model or Path(f"model/{args.split}.bin")
    assert path.stat().st_size < 10 * 1024 * 1024
    model, classes = load_model(path)
    expected_classes, label_offset = (26, 1) if args.split == "letters" else (10, 0)
    assert classes == expected_classes
    orient = transforms.Compose([transforms.ToTensor(), transforms.Lambda(lambda image: image.transpose(-1, -2))])
    test_set = datasets.EMNIST(args.data, split=args.split, train=False, download=False, transform=orient)
    confusion = torch.zeros((classes, classes), dtype=torch.int64)
    for images, labels in DataLoader(test_set, batch_size=512):
        expected = labels - label_offset
        predicted = infer(model, images).argmax(1)
        confusion += torch.bincount(expected * classes + predicted, minlength=classes * classes).reshape(classes, classes)
    symbols = string.ascii_uppercase if args.split == "letters" else string.digits
    overall = confusion.diag().sum().item() / confusion.sum().item()
    print(f"exported {args.split} accuracy: {overall:.2%} ({confusion.sum().item():,} samples)")
    for index, symbol in enumerate(symbols):
        row = confusion[index]
        accuracy = row[index].item() / row.sum().item()
        alternatives = [(symbols[j], row[j].item()) for j in range(classes) if j != index]
        alternatives.sort(key=lambda item: item[1], reverse=True)
        top = ", ".join(f"{name}:{count}" for name, count in alternatives[:3])
        print(f"  {symbol}: {accuracy:6.2%}  top errors {top}")
    print(f"model size: {path.stat().st_size:,} bytes")


if __name__ == "__main__":
    main()

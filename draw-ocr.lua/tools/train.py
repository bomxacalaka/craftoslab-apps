#!/usr/bin/env python3
"""Train and export the compact EMNIST CNNs used by draw-ocr.lua."""

import argparse
import random
import struct
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.utils.data import DataLoader
from torchvision import datasets, transforms


class OcrCnn(nn.Module):
    def __init__(self, classes: int) -> None:
        super().__init__()
        self.conv1 = nn.Conv2d(1, 16, 5)
        self.bn1 = nn.BatchNorm2d(16)
        self.conv2 = nn.Conv2d(16, 32, 3)
        self.bn2 = nn.BatchNorm2d(32)
        self.features = nn.Linear(32 * 5 * 5, 96)
        self.classifier = nn.Linear(96, classes)

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        image = torch.max_pool2d(torch.relu(self.bn1(self.conv1(image))), 2)
        image = torch.max_pool2d(torch.relu(self.bn2(self.conv2(image))), 2)
        image = torch.relu(self.features(image.flatten(1)))
        return self.classifier(image)


def fold_batch_norm(conv: nn.Conv2d, norm: nn.BatchNorm2d) -> tuple[np.ndarray, np.ndarray]:
    weights, bias = conv.weight.detach().cpu(), conv.bias.detach().cpu()
    scale = norm.weight.detach().cpu() / torch.sqrt(norm.running_var.detach().cpu() + norm.eps)
    return (weights * scale[:, None, None, None]).numpy(), (
        (bias - norm.running_mean.detach().cpu()) * scale + norm.bias.detach().cpu()
    ).numpy()


def export_model(model: OcrCnn, path: Path) -> None:
    model.eval()
    conv1_weights, conv1_bias = fold_batch_norm(model.conv1, model.bn1)
    conv2_weights, conv2_bias = fold_batch_norm(model.conv2, model.bn2)
    arrays = (
        conv1_weights, conv1_bias, conv2_weights, conv2_bias,
        model.features.weight.detach().cpu().numpy(), model.features.bias.detach().cpu().numpy(),
        model.classifier.weight.detach().cpu().numpy(), model.classifier.bias.detach().cpu().numpy(),
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as output:
        output.write(struct.pack("<8sIIIIII", b"CCOCR2\0\0", 28, 16, 32, 96, model.classifier.out_features, 2))
        for array in arrays:
            output.write(np.asarray(array, dtype="<f4").tobytes(order="C"))
    print(f"exported {path} ({path.stat().st_size:,} bytes)")


@torch.inference_mode()
def evaluate(model: nn.Module, loader: DataLoader, device: torch.device, label_offset: int) -> float:
    model.eval()
    correct = total = 0
    for images, labels in loader:
        images, labels = images.to(device), (labels - label_offset).to(device)
        correct += (model(images).argmax(1) == labels).sum().item()
        total += labels.numel()
    return correct / total


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--split", choices=("letters", "digits"), required=True)
    parser.add_argument("--data", type=Path, default=Path(".data"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--epochs", type=int, default=12)
    parser.add_argument("--batch-size", type=int, default=256)
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()
    classes, label_offset = (26, 1) if args.split == "letters" else (10, 0)
    output = args.output or Path(f"model/{args.split}.bin")

    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"training {args.split} on {device}")

    orient = transforms.Lambda(lambda image: image.transpose(-1, -2))
    train_transform = transforms.Compose([
        transforms.ToTensor(), orient,
        transforms.RandomAffine(degrees=10, translate=(0.08, 0.08), scale=(0.90, 1.08)),
    ])
    test_transform = transforms.Compose([transforms.ToTensor(), orient])
    train_set = datasets.EMNIST(args.data, split=args.split, train=True, download=True, transform=train_transform)
    test_set = datasets.EMNIST(args.data, split=args.split, train=False, download=True, transform=test_transform)
    workers = min(8, max(1, (torch.get_num_threads() or 2) // 2))
    train_loader = DataLoader(train_set, batch_size=args.batch_size, shuffle=True, num_workers=workers,
                              persistent_workers=True)
    test_loader = DataLoader(test_set, batch_size=args.batch_size * 2, num_workers=workers,
                             persistent_workers=True)

    model = OcrCnn(classes).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=2e-3, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, args.epochs)
    loss_function = nn.CrossEntropyLoss(label_smoothing=0.03)
    best_accuracy, best_state = 0.0, None
    for epoch in range(1, args.epochs + 1):
        model.train()
        running_loss = 0.0
        for images, labels in train_loader:
            images, labels = images.to(device), (labels - label_offset).to(device)
            optimizer.zero_grad(set_to_none=True)
            loss = loss_function(model(images), labels)
            loss.backward()
            optimizer.step()
            running_loss += loss.item() * labels.numel()
        scheduler.step()
        accuracy = evaluate(model, test_loader, device, label_offset)
        print(f"epoch {epoch:02d}: loss={running_loss / len(train_set):.4f} test_accuracy={accuracy:.2%}")
        if accuracy > best_accuracy:
            best_accuracy = accuracy
            best_state = {name: value.detach().cpu().clone() for name, value in model.state_dict().items()}

    assert best_state is not None
    model.load_state_dict(best_state)
    export_model(model, output)
    print(f"best {args.split} test accuracy: {best_accuracy:.2%}")


if __name__ == "__main__":
    main()

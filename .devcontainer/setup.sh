#!/bin/bash
set -e

echo "Installing mise CLI..."
curl https://mise.run | sh
export PATH="$HOME/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc

# Activate mise for bash
echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc

echo "Running mise trust..."
~/.local/bin/mise trust

echo "Installing pipx via pip..."
pip install pipx

echo "Running mise install..."
~/.local/bin/mise install

echo "Logging out of ghcr.io registries..."
docker logout ghcr.io || true
helm registry logout ghcr.io || true

echo "Setup complete!"

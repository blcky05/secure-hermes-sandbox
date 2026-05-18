# Specification: Secure Hermes Web Search via Docker Sandbox

## 1. Project Overview
**Goal:** Create a one-click deployable repository that sets up an AI agent ("Hermes") inside a secure, network-isolated Docker Sandbox (micro-VM), with a safe, read-only web search capability powered by Firecrawl. Data exfiltration is prevented by passing all search queries through a Python-based Sanitizer Proxy backed by Microsoft Presidio.

**Target Audience/Environment:** - macOS (zsh preferred, bash compatible).
- Requires Docker Desktop with AI Sandbox capabilities enabled.

## 2. Architecture & Networking
The architecture enforces a strict hardware-level privacy boundary using Docker AI Sandboxes.

* **Hermes (Agent):** Runs inside a Docker Sandbox (`docker sbx`). It has **NO** direct internet access. It is only allowed to communicate with the local `sanitizer-proxy`.
* **Sanitizer Proxy:** A Flask app running in a standard Docker container. Intercepts queries, routes them to Presidio for scrubbing, and forwards clean queries to Firecrawl.
* **Presidio Analyzer & Anonymizer:** Standard Docker containers. Detects and redacts PII, Credit Cards, and API Keys.
* **Firecrawl:** Standard Docker container. Performs the actual web search.
* **Volume Mount:** A local folder `./HermesWorkspace` is mounted into the Hermes sandbox so the user can interact with files.

## 3. Directory Structure
The AI agent must generate a repository with the exact following structure:

```text
secure-hermes-sandbox/
│
├── setup.sh                 # One-click setup and start script
├── docker-compose.yml       # Orchestrates Proxy, Presidio, and Firecrawl
├── .env.example             # Template for API keys (if needed by Firecrawl/Hermes)
│
├── sandbox/                 # Docker Sandbox definition for Hermes
│   └── Sandbox.Dockerfile   # Dockerfile customized for Docker SBX
│
├── sanitizer_proxy/         # The custom middleware
│   ├── Dockerfile
│   ├── requirements.txt
│   └── app.py
│
└── HermesWorkspace/         # Local volume mount (created by setup.sh)
    └── .gitkeep

4. Component Specifications (Agent Instructions)
4.1. Docker Sandbox (sandbox/Sandbox.Dockerfile)
• Reference: Must adhere to official Docker Sandbox guidelines: https://docs.docker.com/ai/sandboxes/customize/
• Base: Use a standard lightweight base image (e.g., Ubuntu or Python depending on Hermes' dependencies).
• Setup: Pre-install the latest version of "Hermes".
• Networking Constraints: The sandbox configuration must restrict outbound network access. It should ONLY be able to resolve and reach the sanitizer-proxy container on its exposed port.
• Mounts: Configure the sandbox to mount the host's ./HermesWorkspace to /workspace inside the micro-VM.
4.2. Docker Compose (docker-compose.yml)
Define the supporting backend services:
1. presidio-analyzer: mcr.microsoft.com/presidio-analyzer:latest (Port 5001).
2. presidio-anonymizer: mcr.microsoft.com/presidio-anonymizer:latest (Port 5002).
3. firecrawl: mendableai/firecrawl:latest (Port 3002).
4. sanitizer-proxy: Build from ./sanitizer_proxy. Expose Port 5000. Must depend on the other three services.
• Network: Create a dedicated bridge network secure-search-net for these services. Ensure the proxy port (5000) is accessible to the host/sandbox bridge.
4.3. Sanitizer Proxy (sanitizer_proxy/app.py)
• Framework: Python + Flask.
• Logic: 1. Receive POST requests at /search from Hermes. 2. Extract the query string. 3. Send to Presidio Analyzer (include Custom Recognizers for API keys like sk-[a-zA-Z0-9]{20,}). 4. Send to Presidio Anonymizer to redact findings. 5. Forward the anonymized query to Firecrawl's API endpoint. 6. Return Firecrawl's response back to Hermes.
• Error Handling: Ensure timeouts and graceful fallbacks if Presidio or Firecrawl are unavailable.
4.4. Setup Script (setup.sh)
• Shell: #!/usr/bin/env zsh (Ensure standard bash compatibility where possible).
• Tasks: 1. Check for Docker installation and docker sbx CLI availability. 2. Create the ./HermesWorkspace directory if it doesn't exist. 3. Copy .env.example to .env if .env does not exist, prompting the user that Hermes/Firecrawl keys need to be added manually later. 4. Run docker-compose up --build -d to spin up Presidio, Firecrawl, and the Proxy. 5. Wait/poll for the proxy (localhost:5000) to become healthy. 6. Build and run the Hermes sandbox using the appropriate docker sbx command, passing the proxy URL as an environment variable (e.g., SEARCH_TOOL_URL=http://<proxy-ip>:5000/search) and mounting ./HermesWorkspace to /workspace.
• Output: Print clear, color-coded success messages and next steps for the user (e.g., "Hermes Sandbox is running! Configure your provider keys in the sandbox to begin.").
5. Acceptance Criteria
• [ ] Running ./setup.sh spins up the entire environment from scratch on a macOS machine.
• [ ] Hermes is securely enclosed in a docker sbx micro-VM without open internet access.
• [ ] If Hermes attempts to query a search containing an API key or Credit Card, the Proxy logs confirm the text was redacted before reaching Firecrawl.
• [ ] User files placed in ./HermesWorkspace on the macOS host are instantly visible to Hermes inside the sandbox.
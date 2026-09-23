# Project Description

## What It Does

`kwisatz` is a collection of modular, idempotent Bash scripts that automate the provisioning of Ubuntu machines for LLM (Large Language Model) development and server workflows. A single entrypoint script installs and configures an entire stack — from system packages and SSH hardening to Docker, LM Studio, Forgejo, and firewall rules.

## Problem It Solves

Setting up a development or server machine for LLM work is tedious, error-prone, and hard to reproduce. Each tool has its own installation steps, dependencies, and configuration quirks. This project reduces the entire process to a single command, producing a consistent, repeatable environment every time.

## Primary Users

- Developers and ML engineers who need to quickly spin up LLM-ready workstations or headless servers on Ubuntu.
- Intended to be open-sourced for the broader developer community.

## Core Capabilities

- **Modular task scripts** — Each `setup-*.sh` script is self-contained and idempotent; scripts can be run individually or composed via entrypoints.
- **One entrypoints** — `run-setup.sh`
- **Environment-variable configuration** — All tunable values (ports, versions, feature flags) have sensible defaults and can be overridden without editing scripts.
- **Core provisioning** — System packages, SSH (custom port, key-only auth), Docker, LM Studio (with optional `lms` CLI), UFW firewall.
- **Optional components** — Brave browser, VS Code, ROCm (AMD GPU), Samba file sharing, Opencode server, Forgejo (self-hosted Git), AnyDesk, Excalidraw, ...
- **Utility scripts** — SSH tunnel helper for forwarding local ports to remote services (LM Studio, OpenWebUI, Opencode).

## Out of Scope

- **Non-Linux platforms** — No Windows or macOS support. Ubuntu only.
- **Application-level configuration** — The scripts install and configure services but do not manage application state (e.g., which LLM models to download, Forgejo repository setup, OpenWebUI preferences).
- **Ongoing service management** — The project handles initial provisioning, not day-to-day operations, monitoring, or updates.

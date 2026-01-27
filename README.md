# EnergyIntegrationWebApp

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://EnergyIntegration.github.io/EnergyIntegrationWebApp.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://EnergyIntegration.github.io/EnergyIntegrationWebApp.jl/dev/)
[![Build Status](https://github.com/EnergyIntegration/EnergyIntegrationWebApp.jl/actions/workflows/CI.yml/badge.svg?branch=master)](https://github.com/EnergyIntegration/EnergyIntegrationWebApp.jl/actions/workflows/CI.yml?query=branch%3Amaster)
[![ColPrac: Contributor's Guide on Collaborative Practices for Community Packages](https://img.shields.io/badge/ColPrac-Contributor's%20Guide-blueviolet)](https://github.com/SciML/ColPrac)
[![PkgEval](https://JuliaCI.github.io/NanosoldierReports/pkgeval_badges/E/EnergyIntegrationWebApp.svg)](https://JuliaCI.github.io/NanosoldierReports/pkgeval_badges/E/EnergyIntegrationWebApp.html)


EnergyIntegrationWebApp.jl is the Julia backend service for the EnergyIntegration
web UI. It exposes a JSON API for building and solving HEN problems and serves the
prebuilt frontend assets via Julia Artifacts.

Related repos:

- [EnergyIntegration.jl](https://github.com/EnergyIntegration/EnergyIntegration.jl): core algorithms and data structures. 
- [EnergyIntegrationWebApp](https://github.com/EnergyIntegration/EnergyIntegrationWebApp): React UI and static assets. 

## Quick start

```julia
using EnergyIntegrationWebApp
serve_webapp()
```

By default, the server loads frontend assets from the `webapp_dist` artifact. You
can override the dist path with `ENV["EIWEBAPP_DIST"]` or `dist_dir`.

## Updating the frontend artifact

When a new frontend release is published, update `Artifacts.toml` with:

```julia
include("scripts/update_artifact.jl")
main("v0.1.0")
```

This downloads the release tarball, computes hashes, and updates the artifact
entry.
